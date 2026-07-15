import Supabase
import XCTest
@testable import Tripto

/// `AvatarStorage` (P8a — avatar photos): the `avatars`-bucket upload +
/// public-URL builder. `StubAvatarBucket` substitutes for a live
/// `Supa.client.storage` call — `TriptoTests` are hermetic (CLAUDE.md),
/// and this is the one seam the P8a brief calls out by name ("upload-failure
/// atomicity with a stubbed storage protocol").
private final class StubAvatarBucket: AvatarBucketUploading, @unchecked Sendable {
    private(set) var uploadedPath: String?
    private(set) var uploadedData: Data?
    private(set) var uploadedOptions: FileOptions?
    var errorToThrow: Error?

    func upload(_ path: String, data: Data, options: FileOptions) async throws {
        if let errorToThrow {
            throw errorToThrow
        }
        uploadedPath = path
        uploadedData = data
        uploadedOptions = options
    }
}

private struct StubUploadError: Error {}

final class AvatarStorageTests: XCTestCase {
    func testUploadWritesToTheUploadersOwnFolderWithAJPGExtension() async throws {
        let stub = StubAvatarBucket()
        let userId = UUID()
        let jpeg = Data([0xFF, 0xD8, 0xFF])

        _ = try await AvatarStorage.upload(jpeg, for: userId, via: stub)

        let path = try XCTUnwrap(stub.uploadedPath)
        XCTAssertTrue(path.hasPrefix("\(userId.uuidString)/"))
        XCTAssertTrue(path.hasSuffix(".jpg"))
        // Owner-folder segment, then a fresh UUID filename (plan D2) —
        // exactly two path components, never nested deeper.
        let components = path.split(separator: "/")
        XCTAssertEqual(components.count, 2)
        XCTAssertNotNil(UUID(uuidString: String(components[1].dropLast(".jpg".count))))
        XCTAssertEqual(stub.uploadedData, jpeg)
        XCTAssertEqual(stub.uploadedOptions?.contentType, "image/jpeg")
    }

    func testUploadReturnsExactlyThePathItWroteTo() async throws {
        let stub = StubAvatarBucket()
        let path = try await AvatarStorage.upload(Data([0x01]), for: UUID(), via: stub)
        XCTAssertEqual(path, stub.uploadedPath)
    }

    /// Two uploads for the same user never collide on a filename — each
    /// mints its own fresh UUID (plan D2's "new UUID filename per upload").
    func testTwoUploadsForTheSameUserGetDifferentPaths() async throws {
        let stub = StubAvatarBucket()
        let userId = UUID()
        let firstPath = try await AvatarStorage.upload(Data([0x01]), for: userId, via: stub)
        let secondPath = try await AvatarStorage.upload(Data([0x02]), for: userId, via: stub)
        XCTAssertNotEqual(firstPath, secondPath)
    }

    /// P8a brief: "no path write on failed upload — atomicity." `upload`
    /// itself owns no model/row state, so the real guarantee this proves is
    /// that a failure propagates as a thrown error rather than silently
    /// returning a path — every caller's own `avatarPath = try await
    /// AvatarStorage.upload(...)` then naturally never executes the
    /// assignment on failure.
    func testUploadPropagatesAStorageFailureWithoutReturningAPath() async throws {
        let stub = StubAvatarBucket()
        stub.errorToThrow = StubUploadError()

        do {
            _ = try await AvatarStorage.upload(Data([0x01]), for: UUID(), via: stub)
            XCTFail("expected upload to throw")
        } catch is StubUploadError {
            // Expected — and the stub never recorded a path, confirming
            // nothing was written before the throw.
            XCTAssertNil(stub.uploadedPath)
        }
    }

    func testPublicURLBuildsTheExpectedSupabaseStorageURL() {
        let url = AvatarStorage.publicURL(for: "abc-123/def-456.jpg")
        XCTAssertEqual(
            url?.absoluteString,
            "https://qgtveaqukvbtyunupzhn.supabase.co/storage/v1/object/public/avatars/abc-123/def-456.jpg"
        )
    }

    func testPublicURLIsPureAndDeterministicForTheSamePath() {
        let path = "\(UUID().uuidString)/\(UUID().uuidString).jpg"
        XCTAssertEqual(AvatarStorage.publicURL(for: path), AvatarStorage.publicURL(for: path))
    }
}
