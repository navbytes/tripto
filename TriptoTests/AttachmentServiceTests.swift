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
