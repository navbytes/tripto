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
    func attach(
        data: Data, contentType: AttachmentContentType, fileName: String, to item: ItineraryItem
    ) async throws -> ItemAttachment {
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
            id: attachmentId, tripId: item.tripId, itemId: item.id, fileName: fileName,
            contentType: contentType.rawValue, byteSize: payload.count, storagePath: path,
            createdBy: uploaderUserId, createdAt: .now
        )
        let model = ItemAttachment(dto: dto)
        modelContext.insert(model)
        try modelContext.save()
        await syncEngine?.enqueueUpsert(table: .itemAttachments, rowId: attachmentId, tripId: item.tripId, payload: dto)
        return model
    }

    /// UI-affordance mirror of the server RLS delete rule (C1: `USING
    /// created_by = auth.uid() OR trip_role(trip_id) = 'organizer'`) lives at
    /// the call site (`AttachmentStrip.canDelete`), never here — this method
    /// itself performs the delete unconditionally, same as
    /// `BookingDetailView.deleteItem`/`ItemPermissions`'s own split between
    /// "can the button show" and "does the write itself check again."
    func delete(_ attachment: ItemAttachment) async throws {
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
    func localFileURL(for attachment: ItemAttachment) async throws -> URL {
        if let cached = AttachmentStore.cachedFileURL(id: attachment.id, contentType: attachment.contentType) {
            return cached
        }
        let data = try await AttachmentStorage.download(path: attachment.storagePath, via: bucket)
        return try AttachmentStore.write(data, id: attachment.id, contentType: attachment.contentType)
    }
}
