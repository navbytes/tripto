import Supabase
import XCTest
@testable import Tripto

/// `CoverStorage` (P8b — photo trip covers): the `trip-covers`-bucket
/// upload + public-URL builder. Mirrors `AvatarStorageTests` exactly (same
/// `AvatarBucketUploading` stub seam, `TriptoTests` are hermetic per
/// CLAUDE.md) — the two storage types are siblings, so their tests are too.
private final class StubCoverBucket: AvatarBucketUploading, @unchecked Sendable {
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

final class CoverStorageTests: XCTestCase {
    func testUploadWritesToTheUploadersOwnFolderWithAJPGExtension() async throws {
        let stub = StubCoverBucket()
        let userId = UUID()
        let jpeg = Data([0xFF, 0xD8, 0xFF])

        _ = try await CoverStorage.upload(jpeg, for: userId, via: stub)

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
        let stub = StubCoverBucket()
        let path = try await CoverStorage.upload(Data([0x01]), for: UUID(), via: stub)
        XCTAssertEqual(path, stub.uploadedPath)
    }

    /// Two uploads for the same user never collide on a filename — each
    /// mints its own fresh UUID (plan D2's "new UUID filename per upload").
    func testTwoUploadsForTheSameUserGetDifferentPaths() async throws {
        let stub = StubCoverBucket()
        let userId = UUID()
        let firstPath = try await CoverStorage.upload(Data([0x01]), for: userId, via: stub)
        let secondPath = try await CoverStorage.upload(Data([0x02]), for: userId, via: stub)
        XCTAssertNotEqual(firstPath, secondPath)
    }

    /// P8b brief: "atomic: no path without successful upload." `upload`
    /// itself owns no model/row state, so the real guarantee this proves is
    /// that a failure propagates as a thrown error rather than silently
    /// returning a path — `TripFormView.uploadCoverPhoto`'s own `coverImagePath
    /// = try await CoverStorage.upload(...)` then naturally never executes
    /// the assignment on failure.
    func testUploadPropagatesAStorageFailureWithoutReturningAPath() async throws {
        let stub = StubCoverBucket()
        stub.errorToThrow = StubUploadError()

        do {
            _ = try await CoverStorage.upload(Data([0x01]), for: UUID(), via: stub)
            XCTFail("expected upload to throw")
        } catch is StubUploadError {
            // Expected — and the stub never recorded a path, confirming
            // nothing was written before the throw.
            XCTAssertNil(stub.uploadedPath)
        }
    }

    /// Same atomicity, verified at the ROW level (a real `Trip`, unattached —
    /// no `ModelContainer` needed) rather than just the stub's own
    /// bookkeeping — mirrors `AvatarStorageTests
    /// .testFailedUploadLeavesAnExistingRowsAvatarPathUntouchedForBothProfileTypes`.
    /// This is the exact caller shape `TripFormView.uploadCoverPhoto` uses:
    /// `coverImagePath = try await CoverStorage.upload(...)` inside a
    /// `do`/`catch`, against a trip that already has an existing cover photo
    /// — a regression that assigned the path unconditionally (e.g. hoisted
    /// above the `try`) would flip this from "throws, row untouched" to
    /// "silently succeeds with a stale/empty row."
    func testFailedUploadLeavesAnExistingTripsCoverImagePathUntouched() async throws {
        let stub = StubCoverBucket()
        stub.errorToThrow = StubUploadError()

        let trip = TestFixtures.makeTrip(startDate: .now, endDate: .now.addingTimeInterval(86_400))
        trip.coverImagePath = "existing/old-cover.jpg"
        do {
            trip.coverImagePath = try await CoverStorage.upload(Data([0x01]), for: UUID(), via: stub)
            XCTFail("expected upload to throw before the assignment ran")
        } catch is StubUploadError {
            XCTAssertEqual(trip.coverImagePath, "existing/old-cover.jpg")
        }
    }

    func testPublicURLBuildsTheExpectedSupabaseStorageURLUnderTheTripCoversBucket() {
        let url = CoverStorage.publicURL(for: "abc-123/def-456.jpg")
        XCTAssertEqual(
            url?.absoluteString,
            "https://qgtveaqukvbtyunupzhn.supabase.co/storage/v1/object/public/trip-covers/abc-123/def-456.jpg"
        )
    }

    func testPublicURLIsPureAndDeterministicForTheSamePath() {
        let path = "\(UUID().uuidString)/\(UUID().uuidString).jpg"
        XCTAssertEqual(CoverStorage.publicURL(for: path), CoverStorage.publicURL(for: path))
    }

    /// The one thing genuinely worth pinning about the sibling split (vs.
    /// generalizing `AvatarStorage`): the two buckets must never collide on
    /// the same path string.
    func testCoverAndAvatarPublicURLsDifferOnlyByBucketNameForTheSamePath() {
        let path = "\(UUID().uuidString)/\(UUID().uuidString).jpg"
        XCTAssertNotEqual(CoverStorage.publicURL(for: path), AvatarStorage.publicURL(for: path))
        XCTAssertEqual(CoverStorage.bucket, "trip-covers")
        XCTAssertEqual(AvatarStorage.bucket, "avatars")
    }
}
