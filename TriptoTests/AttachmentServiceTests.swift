import Supabase
import SwiftData
import XCTest
@testable import Tripto

/// C2 (`.claude/company/release-1.2/PLAN.md`): `AttachmentService.attach`/
/// `delete`/`localFileURL` against a stubbed `AttachmentBucketAccessing` —
/// same "let tests substitute a stub, `TriptoTests` never touch a live
/// network/auth session" seam `AvatarStorageTests`/`CoverStorageTests`
/// already use for the public buckets, widened to cover download/remove.
/// `syncEngine: nil` throughout: the outbox half of `attach`/`delete` is
/// already covered hermetically at the `SyncStore` level
/// (`ItemAttachmentSyncTests`) — constructing a real `SyncEngine` here would
/// risk a genuine stray network call once its own debounced push loop fires
/// (see `SyncEnginePushLoopTests`'s doc comment on that exact risk), which a
/// hermetic suite must not do for a validly-encoded payload.
///
/// W3 review H1 fix: `AttachmentService.attach`/`delete`/`localFileURL` are
/// now `@MainActor`. Every test method here is a plain (non-`@MainActor`)
/// `async throws` XCTest method, so calling `try await service.attach(...)`
/// genuinely exercises the cross-actor hop into those `@MainActor` methods —
/// and `MainActor.assertIsolated()` inside each of them (see
/// `AttachmentService`'s own doc comment) means EVERY test in this file, not
/// just one dedicated case, traps immediately if that isolation ever
/// regresses. Tried switching `makeContext()` to the container's real
/// `mainContext` (closer still to production's `@Environment(\.modelContext)`)
/// to close the reviewer's own diagnosed blind spot ("a fresh context has no
/// main-thread affinity") — reverted: a freshly-created in-memory
/// `ModelContainer`'s `mainContext`, accessed from a `Task` that just hopped
/// onto `MainActor` itself, deadlocks in this Xcode/SDK's XCTest host (every
/// context-touching test timed out and the runner restarted, confirmed by
/// the pure `sanitizedFileName` tests below — no context involved — passing
/// instantly). The isolation fix itself doesn't need `mainContext`
/// specifically to be proven: `@MainActor` on the service methods is what's
/// under test, and a plain, freestanding `ModelContext` has no thread
/// affinity of its own either way, so running it via the now-forced
/// actor-hop is a faithful enough exercise of the real bug's mechanism.
private final class StubAttachmentBucket: AttachmentBucketAccessing, @unchecked Sendable {
    private(set) var uploadedPath: String?
    private(set) var uploadedData: Data?
    private(set) var uploadedOptions: FileOptions?
    private(set) var removedPaths: [String] = []
    private(set) var downloadedPaths: [String] = []
    var dataToReturnOnDownload = Data()
    var uploadError: Error?
    var removeError: Error?
    var downloadError: Error?

    func upload(_ path: String, data: Data, options: FileOptions) async throws {
        if let uploadError { throw uploadError }
        uploadedPath = path
        uploadedData = data
        uploadedOptions = options
    }

    func remove(paths: [String]) async throws {
        if let removeError { throw removeError }
        removedPaths.append(contentsOf: paths)
    }

    func download(_ path: String) async throws -> Data {
        if let downloadError { throw downloadError }
        downloadedPaths.append(path)
        return dataToReturnOnDownload
    }
}

private struct StubError: Error {}

final class AttachmentServiceTests: XCTestCase {
    private func makeContext() -> ModelContext {
        ModelContext(AppSchema.makeContainer(inMemory: true))
    }

    // MARK: - attach()

    func testAttachUploadsPDFVerbatimAndInsertsTheLocalRow() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        let userId = UUID()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: userId, bucket: stub)
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        context.insert(item)
        try context.save()

        let pdfBytes = Data([0x25, 0x50, 0x44, 0x46]) // "%PDF"
        let attachment = try await service.attach(
            data: pdfBytes, contentType: .pdf, fileName: "boarding-pass.pdf", to: item
        )
        defer { AttachmentStore.remove(id: attachment.id, contentType: .pdf) }

        XCTAssertEqual(stub.uploadedData, pdfBytes, "a PDF is uploaded verbatim, never re-encoded")
        XCTAssertEqual(stub.uploadedOptions?.contentType, "application/pdf")
        let expectedPath = AttachmentStorage.path(
            tripId: item.tripId, itemId: item.id, attachmentId: attachment.id, contentType: .pdf
        )
        XCTAssertEqual(stub.uploadedPath, expectedPath)
        XCTAssertEqual(attachment.storagePath, expectedPath)
        XCTAssertEqual(attachment.fileName, "boarding-pass.pdf")
        XCTAssertEqual(attachment.createdBy, userId)
        XCTAssertEqual(attachment.itemId, item.id)
        XCTAssertEqual(attachment.tripId, item.tripId)
        // R-L1's rollback must never fire on the happy path.
        XCTAssertTrue(stub.removedPaths.isEmpty, "a successful attach must never remove the object it just uploaded")

        let rows = try context.fetch(FetchDescriptor<ItemAttachment>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.id, attachment.id)
    }

    func testAttachRejectsAFileOverTenMegabytesWithoutUploading() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: UUID(), bucket: stub)
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        context.insert(item)
        try context.save()

        // PDFs pass through verbatim (no re-encode step to shrink them), so
        // this is the deterministic way to trip the cap without needing a
        // real oversized image to downsample.
        let oversized = Data(count: AttachmentService.maxBytes + 1)

        do {
            _ = try await service.attach(data: oversized, contentType: .pdf, fileName: "huge.pdf", to: item)
            XCTFail("expected fileTooLarge")
        } catch AttachmentServiceError.fileTooLarge {
            XCTAssertNil(stub.uploadedData, "an oversized file must never reach the network")
        }
        XCTAssertTrue(try context.fetch(FetchDescriptor<ItemAttachment>()).isEmpty)
    }

    func testAttachRejectsAnEleventhAttachmentOnTheSameItem() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: UUID(), bucket: stub)
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        context.insert(item)
        for _ in 0..<AttachmentService.maxPerItem {
            context.insert(ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(tripId: item.tripId, itemId: item.id)))
        }
        try context.save()

        do {
            _ = try await service.attach(data: Data([0x25]), contentType: .pdf, fileName: "one-too-many.pdf", to: item)
            XCTFail("expected tooManyAttachments")
        } catch AttachmentServiceError.tooManyAttachments {
            XCTAssertNil(stub.uploadedData, "the cap check must run before any network upload")
        }
    }

    /// A ninth-then-tenth attachment (still under the cap) must succeed —
    /// the regression guard for the boundary the previous test pins from
    /// the other side.
    func testAttachSucceedsAtExactlyTheCapBoundary() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: UUID(), bucket: stub)
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        context.insert(item)
        for _ in 0..<(AttachmentService.maxPerItem - 1) {
            context.insert(ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(tripId: item.tripId, itemId: item.id)))
        }
        try context.save()

        let attachment = try await service.attach(data: Data([0x25]), contentType: .pdf, fileName: "tenth.pdf", to: item)
        defer { AttachmentStore.remove(id: attachment.id, contentType: .pdf) }

        let itemId = item.id
        let count = try context.fetchCount(FetchDescriptor<ItemAttachment>(predicate: #Predicate { $0.itemId == itemId }))
        XCTAssertEqual(count, AttachmentService.maxPerItem)
    }

    func testAttachFailsWithoutASignedInUploaderAndNeverTouchesStorage() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: nil, bucket: stub)
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        context.insert(item)
        try context.save()

        do {
            _ = try await service.attach(data: Data([0x25]), contentType: .pdf, fileName: "x.pdf", to: item)
            XCTFail("expected notSignedIn")
        } catch AttachmentServiceError.notSignedIn {
            XCTAssertNil(stub.uploadedData)
        }
    }

    func testAttachPropagatesAStorageFailureWithoutInsertingALocalRow() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        stub.uploadError = StubError()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: UUID(), bucket: stub)
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        context.insert(item)
        try context.save()

        do {
            _ = try await service.attach(data: Data([0x25]), contentType: .pdf, fileName: "x.pdf", to: item)
            XCTFail("expected upload to throw")
        } catch is StubError {
            XCTAssertTrue(
                try context.fetch(FetchDescriptor<ItemAttachment>()).isEmpty,
                "a failed upload must leave no local row — the storage write happens before the SwiftData insert"
            )
        }
    }

    // MARK: - attach() filename sanitization (S-3)

    /// `fileName` is member-controlled (a `.fileImporter` pick's name is
    /// whatever's on the picking device) and renders verbatim in dialogs,
    /// the VoiceOver label, and the QuickLook nav title — control characters
    /// could break single-line rendering/announcement.
    func testSanitizedFileNameStripsControlCharacters() {
        XCTAssertEqual(
            AttachmentService.sanitizedFileName("bad\nname\t.pdf"), "badname.pdf",
            "newlines/tabs must never survive into a rendered file name"
        )
    }

    func testSanitizedFileNameFallsBackWhenEverythingWasStripped() {
        XCTAssertEqual(AttachmentService.sanitizedFileName("\n\t"), "attachment")
    }

    func testSanitizedFileNameCapsLengthWhilePreservingTheExtension() {
        let huge = String(repeating: "a", count: 300) + ".pdf"
        let sanitized = AttachmentService.sanitizedFileName(huge)
        XCTAssertLessThanOrEqual(sanitized.count, 120)
        XCTAssertTrue(sanitized.hasSuffix(".pdf"), "truncation must not eat the extension")
    }

    func testSanitizedFileNameLeavesAnOrdinaryNameUntouched() {
        XCTAssertEqual(AttachmentService.sanitizedFileName("boarding-pass.pdf"), "boarding-pass.pdf")
    }

    /// End-to-end: `attach` actually calls the sanitizer, not just a
    /// unit-level pure-function proof.
    func testAttachSanitizesTheStoredFileName() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: UUID(), bucket: stub)
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        context.insert(item)
        try context.save()

        let attachment = try await service.attach(
            data: Data([0x25]), contentType: .pdf, fileName: "evil\nname.pdf", to: item
        )
        defer { AttachmentStore.remove(id: attachment.id, contentType: .pdf) }

        XCTAssertEqual(attachment.fileName, "evilname.pdf")
    }

    // MARK: - delete()

    func testDeleteRemovesTheLocalRowAndCallsStorageRemoveWithItsPath() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: UUID(), bucket: stub)
        let attachment = ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO())
        context.insert(attachment)
        try context.save()
        let path = attachment.storagePath

        try await service.delete(attachment)

        XCTAssertTrue(try context.fetch(FetchDescriptor<ItemAttachment>()).isEmpty)
        XCTAssertEqual(stub.removedPaths, [path])
    }

    /// Best-effort storage remove (PLAN.md C2) — an orphaned bucket object
    /// on failure is accepted; the LOCAL delete (and the outbox enqueue,
    /// covered separately) must still go through.
    func testDeleteStillRemovesTheLocalRowEvenIfStorageRemoveFails() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        stub.removeError = StubError()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: UUID(), bucket: stub)
        let attachment = ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO())
        context.insert(attachment)
        try context.save()

        try await service.delete(attachment) // must not throw

        XCTAssertTrue(try context.fetch(FetchDescriptor<ItemAttachment>()).isEmpty)
    }

    // MARK: - localFileURL()

    func testLocalFileURLReturnsTheCachedFileWithoutCallingDownload() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: UUID(), bucket: stub)
        let attachment = ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(contentType: .pdf))
        let cachedURL = try AttachmentStore.write(Data([0x01]), id: attachment.id, contentType: .pdf)
        defer { AttachmentStore.remove(id: attachment.id, contentType: .pdf) }

        let url = try await service.localFileURL(for: attachment)

        XCTAssertEqual(url, cachedURL)
        XCTAssertTrue(stub.downloadedPaths.isEmpty, "a cache hit must never touch the network")
    }

    func testLocalFileURLDownloadsAndCachesWhenNotYetCached() async throws {
        let context = makeContext()
        let stub = StubAttachmentBucket()
        let bytes = Data([0xAA, 0xBB])
        stub.dataToReturnOnDownload = bytes
        let service = AttachmentService(modelContext: context, syncEngine: nil, uploaderUserId: UUID(), bucket: stub)
        let attachment = ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(contentType: .pdf))
        AttachmentStore.remove(id: attachment.id, contentType: .pdf) // ensure a clean slate
        defer { AttachmentStore.remove(id: attachment.id, contentType: .pdf) }

        let url = try await service.localFileURL(for: attachment)

        XCTAssertEqual(stub.downloadedPaths, [attachment.storagePath])
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        XCTAssertEqual(
            AttachmentStore.cachedFileURL(id: attachment.id, contentType: .pdf), url,
            "the download result must be cached for next time"
        )
    }
}
