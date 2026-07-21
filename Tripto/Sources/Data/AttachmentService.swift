import Foundation
import SwiftData
import Supabase

enum AttachmentServiceError: Error, Equatable {
    case fileTooLarge
    case tooManyAttachments
    case notSignedIn
}

/// C2 (`.claude/company/release-1.2/PLAN.md`): the app-side attach/delete/
/// download service for `item_attachments`. `attach`/`delete` are the two
/// halves of "SwiftData write -> SyncEngine.enqueue" every other mutation in
/// this app already follows (SYNC_DESIGN.md), except the STORAGE upload/
/// remove has no outbox of its own — there's nowhere offline to stash raw
/// file bytes for a later retry, so both need a live network round trip
/// before the (resilient, retried) row upsert/delete ever gets enqueued.
///
/// A plain struct, constructed per call site with the same dependencies
/// every other mutation helper in this app already takes
/// (`PackingItem.insert`'s `modelContext:syncEngine:` shape) — no singleton,
/// no environment key.
///
/// Deliberately NOT declared `: AttachmentAttaching` here — that protocol is
/// coder B's file (PLAN.md C2) and didn't exist yet when this was written.
/// `attach`'s signature already matches it exactly, so the conformance is a
/// zero-behavior one-line `extension AttachmentService: AttachmentAttaching
/// {}` for whichever side lands second at integration.
///
/// W3 review H1: `modelContext` is always the caller's `@Environment(\
/// .modelContext)` main context (SwiftUI, `AttachmentStrip`/`PasteImportSheet`/
/// `AddItemSheet`/`TripView`), so every SwiftData touch below MUST run on
/// `MainActor` — a plain `nonisolated async` method invoked via `await` does
/// NOT inherit the caller's actor (SE-0338); it runs on the global executor,
/// mutating the main-queue context off-thread. `attach`/`delete`/
/// `localFileURL` are `@MainActor` for exactly this reason; the network/
/// downsample calls they `await` (`ImageProcessing`, `AttachmentStorage`) are
/// themselves plain nonisolated functions, so Swift still hops OFF main for
/// that work and back on for the model touches — no manual `Task`/
/// `MainActor.run` staging needed, same net effect as `TripFormView
/// .uploadCoverPhoto`'s "async work first, mutate on main" shape. Each
/// model-touching block also carries a cheap `MainActor.assertIsolated()` —
/// stripped in Release, but a loud, immediate trap in Debug/tests if this
/// isolation ever regresses (e.g. the annotation dropped in a refactor)
/// rather than silently reintroducing undefined behavior.
struct AttachmentService {
    let modelContext: ModelContext
    let syncEngine: SyncEngine?
    /// Always the acting/signed-in user (`AuthManager.userId`) — stamped as
    /// `created_by` and, client-side, the uploader half of the "may I delete
    /// this" check (`AttachmentStrip.canDelete`). `nil` (signed out) fails
    /// `attach` with `.notSignedIn` rather than writing an unattributed row;
    /// `delete`/`localFileURL` don't need a real uploader, so callers that
    /// only ever read/remove may pass `nil` too.
    let uploaderUserId: UUID?
    var bucket: AttachmentBucketAccessing = SupabaseAttachmentBucket()

    /// C1/PRODUCT_PLAN.md §2.1: "Caps: 10 files per item, 10 MB per file."
    static let maxBytes = 10 * 1_024 * 1_024
    static let maxPerItem = 10

    /// Re-encodes images to JPEG (`ImageProcessing.attachmentMaxPixelSize`/
    /// `.attachmentCompressionQuality`); PDFs pass through verbatim. The
    /// 10MB cap is checked AFTER that step — checking a raw picked image
    /// against it would reject a large-but-normal HEIC that re-encodes down
    /// to a fraction of its original size, and a verbatim PDF has nothing to
    /// shrink anyway. Upload happens before the row ever lands locally: a
    /// storage path with nothing behind it is useless, so there's no
    /// "insert first, upload later" story here the way every other mutation
    /// in this app gets from the outbox.
    @discardableResult
    @MainActor
    func attach(
        data: Data, contentType: AttachmentContentType, fileName: String, to item: ItineraryItem
    ) async throws -> ItemAttachment {
        MainActor.assertIsolated("AttachmentService.attach must mutate modelContext on MainActor")
        guard let uploaderUserId else { throw AttachmentServiceError.notSignedIn }

        let itemId = item.id
        let existingCount = try modelContext.fetchCount(
            FetchDescriptor<ItemAttachment>(predicate: #Predicate { $0.itemId == itemId })
        )
        guard existingCount < Self.maxPerItem else { throw AttachmentServiceError.tooManyAttachments }

        let payload: Data
        switch contentType {
        case .jpeg:
            payload = try await ImageProcessing.downsampledJPEG(
                data, maxPixelSize: ImageProcessing.attachmentMaxPixelSize,
                compressionQuality: ImageProcessing.attachmentCompressionQuality
            )
        case .pdf:
            payload = data
        }
        guard payload.count <= Self.maxBytes else { throw AttachmentServiceError.fileTooLarge }

        let attachmentId = UUID()
        let path = AttachmentStorage.path(
            tripId: item.tripId, itemId: item.id, attachmentId: attachmentId, contentType: contentType
        )
        try await AttachmentStorage.upload(payload, path: path, contentType: contentType, via: bucket)
        // This device already has the bytes in memory — seed the disk cache
        // now rather than making a later `localFileURL` re-download the
        // very file this device just uploaded.
        try? AttachmentStore.write(payload, id: attachmentId, contentType: contentType)

        let dto = ItemAttachmentDTO(
            id: attachmentId, tripId: item.tripId, itemId: item.id, fileName: Self.sanitizedFileName(fileName),
            contentType: contentType.rawValue, byteSize: payload.count, storagePath: path,
            createdBy: uploaderUserId, createdAt: .now
        )
        let model = ItemAttachment(dto: dto)
        modelContext.insert(model)
        do {
            try modelContext.save()
        } catch {
            // R-L1 (reviewer LOW): the object already landed in storage —
            // a row that fails to save locally has no outbox op to ever
            // land it server-side either, so it would otherwise orphan the
            // upload for good rather than the usual bounded/transient case.
            try? await AttachmentStorage.remove(path: path, via: bucket)
            throw error
        }
        await syncEngine?.enqueueUpsert(table: .itemAttachments, rowId: attachmentId, tripId: item.tripId, payload: dto)
        return model
    }

    /// S-3 (security LOW): `fileName` is member-controlled — a `.fileImporter`
    /// pick's name is whatever's on the picking device's filesystem, shown
    /// verbatim in dialogs, the VoiceOver label, and the QuickLook nav title
    /// (`AttachmentStrip`/`QuickLookPreview`). Strips control characters
    /// (a raw newline/tab could break single-line rendering or a VoiceOver
    /// announcement) and caps length, preserving the extension so
    /// `AttachmentThumbnail`'s doc/photo icon choice (keyed off
    /// `contentType`, never the name) is unaffected either way.
    static func sanitizedFileName(_ raw: String) -> String {
        let noControls = String(raw.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
        let trimmed = noControls.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "attachment" : trimmed
        let maxLength = 120
        guard name.count > maxLength else { return name }
        let ext = (name as NSString).pathExtension
        let base = (name as NSString).deletingPathExtension
        let budget = max(maxLength - (ext.isEmpty ? 0 : ext.count + 1), 1)
        let shortBase = String(base.prefix(budget))
        return ext.isEmpty ? shortBase : "\(shortBase).\(ext)"
    }

    /// UI-affordance mirror of the server RLS delete rule (C1: `USING
    /// created_by = auth.uid() OR trip_role(trip_id) = 'organizer'`) lives at
    /// the call site (`AttachmentStrip.canDelete`), never here — this method
    /// itself performs the delete unconditionally, same as
    /// `BookingDetailView.deleteItem`/`ItemPermissions`'s own split between
    /// "can the button show" and "does the write itself check again."
    @MainActor
    func delete(_ attachment: ItemAttachment) async throws {
        MainActor.assertIsolated("AttachmentService.delete must mutate modelContext on MainActor")
        let rowId = attachment.id
        let tripId = attachment.tripId
        let path = attachment.storagePath
        let contentType = attachment.contentType
        modelContext.delete(attachment)
        try modelContext.save()
        await syncEngine?.enqueueDelete(table: .itemAttachments, rowId: rowId, tripId: tripId)
        // Best-effort — an orphaned storage object on failure is accepted,
        // same v1 policy as `CoverStorage`/`AvatarStorage`'s own doc
        // comments for a replaced photo's old object.
        try? await AttachmentStorage.remove(path: path, via: bucket)
        AttachmentStore.remove(id: rowId, contentType: contentType)
    }

    /// Cache-through download — never a public URL; the bucket is private
    /// (`AttachmentStorage`'s own doc comment).
    @MainActor
    func localFileURL(for attachment: ItemAttachment) async throws -> URL {
        MainActor.assertIsolated("AttachmentService.localFileURL must read @Model props on MainActor")
        if let cached = AttachmentStore.cachedFileURL(id: attachment.id, contentType: attachment.contentType) {
            return cached
        }
        let data = try await AttachmentStorage.download(path: attachment.storagePath, via: bucket)
        return try AttachmentStore.write(data, id: attachment.id, contentType: attachment.contentType)
    }
}
