import Supabase
import XCTest
@testable import Tripto

/// `AttachmentStorage` (release 1.2): the `item-attachments`-bucket path
/// builder + stubbed upload/remove/download. Mirrors `AvatarStorageTests`/
/// `CoverStorageTests` (same `TriptoTests` are hermetic per CLAUDE.md), a
/// stub substituting for a live `Supa.client.storage` call — widened to
/// cover download/remove too since this bucket is read from as well as
/// written to.
private final class StubAttachmentBucket: AttachmentBucketAccessing, @unchecked Sendable {
    private(set) var uploadedPath: String?
    private(set) var uploadedData: Data?
    private(set) var uploadedOptions: FileOptions?
    private(set) var removedPaths: [String] = []
    private(set) var downloadedPaths: [String] = []
    var dataToReturnOnDownload = Data()
    var errorToThrow: Error?

    func upload(_ path: String, data: Data, options: FileOptions) async throws {
        if let errorToThrow { throw errorToThrow }
        uploadedPath = path
        uploadedData = data
        uploadedOptions = options
    }

    func remove(paths: [String]) async throws {
        if let errorToThrow { throw errorToThrow }
        removedPaths.append(contentsOf: paths)
    }

    func download(_ path: String) async throws -> Data {
        if let errorToThrow { throw errorToThrow }
        downloadedPaths.append(path)
        return dataToReturnOnDownload
    }
}

private struct StubError: Error {}

final class AttachmentStorageTests: XCTestCase {
    // MARK: - path(tripId:itemId:attachmentId:contentType:)

    func testPathIsTripSlashItemSlashAttachmentIdWithTheJPGExtension() {
        let tripId = UUID()
        let itemId = UUID()
        let attachmentId = UUID()

        let path = AttachmentStorage.path(tripId: tripId, itemId: itemId, attachmentId: attachmentId, contentType: .jpeg)

        XCTAssertEqual(
            path,
            "\(tripId.uuidString.lowercased())/\(itemId.uuidString.lowercased())/"
                + "\(attachmentId.uuidString.lowercased()).jpg"
        )
    }

    func testPathUsesThePDFExtensionForPDFContentType() {
        let path = AttachmentStorage.path(tripId: UUID(), itemId: UUID(), attachmentId: UUID(), contentType: .pdf)
        XCTAssertTrue(path.hasSuffix(".pdf"))
    }

    /// Regression (mirrors `AvatarStorageTests`' identical-purpose test):
    /// the storage RLS policies (C1) compare
    /// `(storage.foldername(name))[1]`/`[2]` against Postgres's own
    /// lowercase `uuid::text` rendering; Foundation's `UUID.uuidString` is
    /// UPPERCASE, so an unlowercased segment fails every real call. Uses ids
    /// with hex letters so upper-/lower-case forms actually differ.
    func testTripAndItemSegmentsAreLowercasedToMatchRLSUuidTextRendering() throws {
        let tripId = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))
        let itemId = try XCTUnwrap(UUID(uuidString: "FFFFFFFF-1111-4222-8333-444444444444"))

        let path = AttachmentStorage.path(tripId: tripId, itemId: itemId, attachmentId: UUID(), contentType: .jpeg)
        let segments = path.split(separator: "/")

        XCTAssertEqual(segments.count, 3, "trip / item / filename — never nested deeper")
        XCTAssertEqual(String(segments[0]), tripId.uuidString.lowercased())
        XCTAssertEqual(String(segments[1]), itemId.uuidString.lowercased())
        XCTAssertNotEqual(String(segments[0]), tripId.uuidString, "an uppercase segment fails the RLS uuid::text check")
    }

    func testTwoAttachmentsOnTheSameItemGetDifferentPaths() {
        let tripId = UUID()
        let itemId = UUID()
        let first = AttachmentStorage.path(tripId: tripId, itemId: itemId, attachmentId: UUID(), contentType: .jpeg)
        let second = AttachmentStorage.path(tripId: tripId, itemId: itemId, attachmentId: UUID(), contentType: .jpeg)
        XCTAssertNotEqual(first, second)
    }

    // MARK: - upload/remove/download (stubbed)

    func testUploadPassesTheContentTypeAsTheMIMEOption() async throws {
        let stub = StubAttachmentBucket()
        let data = Data([0xFF, 0xD8, 0xFF])
        try await AttachmentStorage.upload(data, path: "a/b/c.jpg", contentType: .jpeg, via: stub)
        XCTAssertEqual(stub.uploadedPath, "a/b/c.jpg")
        XCTAssertEqual(stub.uploadedData, data)
        XCTAssertEqual(stub.uploadedOptions?.contentType, "image/jpeg")
    }

    func testUploadPropagatesAStorageFailure() async throws {
        let stub = StubAttachmentBucket()
        stub.errorToThrow = StubError()
        do {
            try await AttachmentStorage.upload(Data([0x01]), path: "a/b/c.pdf", contentType: .pdf, via: stub)
            XCTFail("expected upload to throw")
        } catch is StubError {}
    }

    func testRemoveSendsExactlyTheOnePathAsASingleElementArray() async throws {
        let stub = StubAttachmentBucket()
        try await AttachmentStorage.remove(path: "a/b/c.jpg", via: stub)
        XCTAssertEqual(stub.removedPaths, ["a/b/c.jpg"])
    }

    func testDownloadReturnsExactlyWhatTheBucketHandsBack() async throws {
        let stub = StubAttachmentBucket()
        stub.dataToReturnOnDownload = Data([0x10, 0x20, 0x30])
        let data = try await AttachmentStorage.download(path: "a/b/c.pdf", via: stub)
        XCTAssertEqual(data, Data([0x10, 0x20, 0x30]))
        XCTAssertEqual(stub.downloadedPaths, ["a/b/c.pdf"])
    }

    func testDownloadPropagatesAStorageFailure() async throws {
        let stub = StubAttachmentBucket()
        stub.errorToThrow = StubError()
        do {
            _ = try await AttachmentStorage.download(path: "a/b/c.pdf", via: stub)
            XCTFail("expected download to throw")
        } catch is StubError {}
    }

    func testBucketIsItemAttachments() {
        XCTAssertEqual(AttachmentStorage.bucket, "item-attachments")
    }
}
