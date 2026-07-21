import SwiftData
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

    // MARK: - removeAll() (security audit S-1: cache must not survive sign-out)

    func testRemoveAllDeletesEveryCachedFile() throws {
        let idA = UUID()
        let idB = UUID()
        _ = try AttachmentStore.write(Data([0x01]), id: idA, contentType: .jpeg)
        _ = try AttachmentStore.write(Data([0x02]), id: idB, contentType: .pdf)

        AttachmentStore.removeAll()

        XCTAssertNil(AttachmentStore.cachedFileURL(id: idA, contentType: .jpeg))
        XCTAssertNil(AttachmentStore.cachedFileURL(id: idB, contentType: .pdf))
    }

    func testRemoveAllOnAnEmptyOrNeverCreatedCacheIsANoOp() {
        AttachmentStore.removeAll() // must not throw/crash even if nothing was ever written
    }

    /// `write` must self-heal after a wipe (a later attach/prefetch on the
    /// same run shouldn't ever hit a missing-directory error).
    func testWriteAfterRemoveAllRecreatesTheDirectory() throws {
        let id = UUID()
        defer { AttachmentStore.remove(id: id, contentType: .jpeg) }
        AttachmentStore.removeAll() // simulate a prior sign-out wipe

        let url = try AttachmentStore.write(Data([0x01]), id: id, contentType: .jpeg)

        XCTAssertEqual(try Data(contentsOf: url), Data([0x01]))
    }

    /// Security audit S-1: "server is the source of truth, cache is
    /// re-downloadable" — the whole cache directory must never ride along
    /// in an iCloud/iTunes device backup.
    func testWriteExcludesTheCacheDirectoryFromBackup() throws {
        let id = UUID()
        defer { AttachmentStore.remove(id: id, contentType: .jpeg) }
        let url = try AttachmentStore.write(Data([0x01]), id: id, contentType: .jpeg)

        let values = try url.deletingLastPathComponent().resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
    }

    /// End-to-end: `SyncEngine.wipeForSignOut` (the seam the security audit
    /// named) actually reaches the disk cache, not just the mirrored rows
    /// `SyncStore.wipeAll` already clears. Safe to construct a real
    /// `SyncEngine` here (unlike a push-triggering test) — this engine never
    /// calls `start()`/opens a realtime channel, so `wipeForSignOut`'s own
    /// `stopAllRealtime()` has nothing to tear down and never touches the
    /// network.
    func testSyncEngineWipeForSignOutClearsTheAttachmentDiskCache() async throws {
        let id = UUID()
        _ = try AttachmentStore.write(Data([0x01]), id: id, contentType: .pdf)

        let container = AppSchema.makeContainer(inMemory: true)
        let engine = SyncEngine(modelContainer: container, status: await SyncStatus(), forcedOnline: true)
        await engine.wipeForSignOut()

        XCTAssertNil(
            AttachmentStore.cachedFileURL(id: id, contentType: .pdf),
            "sign-out (and delete-account, which routes through the same call) must clear cached attachment bytes, not just rows"
        )
    }
}
