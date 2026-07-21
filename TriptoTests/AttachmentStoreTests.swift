import XCTest
@testable import Tripto

/// `AttachmentStore` (release 1.2): the Application Support disk cache.
/// Real `FileManager` I/O against the simulator's own sandboxed directory —
/// no network, so no stub/protocol seam is needed for this to stay hermetic
/// (`AttachmentStore`'s own doc comment).
final class AttachmentStoreTests: XCTestCase {
    func testCachedFileURLIsNilBeforeAnythingIsWritten() {
        XCTAssertNil(AttachmentStore.cachedFileURL(id: UUID(), contentType: .pdf))
    }

    func testWriteThenCachedFileURLRoundTripsTheSameBytes() throws {
        let id = UUID()
        defer { AttachmentStore.remove(id: id, contentType: .pdf) }
        let data = Data([0x25, 0x50, 0x44, 0x46])

        let writtenURL = try AttachmentStore.write(data, id: id, contentType: .pdf)

        let cachedURL = try XCTUnwrap(AttachmentStore.cachedFileURL(id: id, contentType: .pdf))
        XCTAssertEqual(cachedURL, writtenURL)
        XCTAssertEqual(try Data(contentsOf: cachedURL), data)
    }

    func testWriteTwiceOverwritesRatherThanErroring() throws {
        let id = UUID()
        defer { AttachmentStore.remove(id: id, contentType: .jpeg) }
        _ = try AttachmentStore.write(Data([0x01]), id: id, contentType: .jpeg)

        let url = try AttachmentStore.write(Data([0x02, 0x03]), id: id, contentType: .jpeg)

        XCTAssertEqual(try Data(contentsOf: url), Data([0x02, 0x03]))
    }

    func testRemoveClearsTheCacheHit() throws {
        let id = UUID()
        _ = try AttachmentStore.write(Data([0x01]), id: id, contentType: .jpeg)

        AttachmentStore.remove(id: id, contentType: .jpeg)

        XCTAssertNil(AttachmentStore.cachedFileURL(id: id, contentType: .jpeg))
    }

    func testRemoveOnANeverWrittenIdIsANoOp() {
        AttachmentStore.remove(id: UUID(), contentType: .pdf) // must not throw/crash
    }

    /// Two content types for the same id are two distinct files — the
    /// extension is part of the cache key. Realistically never exercised (an
    /// id is always paired with the one content type it was created with),
    /// but pins that the filename scheme doesn't silently collide.
    func testJPEGAndPDFCacheEntriesForTheSameIdAreDistinctFiles() throws {
        let id = UUID()
        defer {
            AttachmentStore.remove(id: id, contentType: .jpeg)
            AttachmentStore.remove(id: id, contentType: .pdf)
        }
        let jpegURL = try AttachmentStore.write(Data([0x01]), id: id, contentType: .jpeg)
        let pdfURL = try AttachmentStore.write(Data([0x02]), id: id, contentType: .pdf)
        XCTAssertNotEqual(jpegURL, pdfURL)
    }
}
