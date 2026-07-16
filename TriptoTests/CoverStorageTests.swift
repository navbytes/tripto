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
        // Lowercased owner folder — matches the storage RLS `auth.uid()::text`
        // check (see `testUploadFolderSegmentIsLowercasedToMatchRLSAuthUidText`).
        XCTAssertTrue(path.hasPrefix("\(userId.uuidString.lowercased())/"))
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

    /// Regression (photo-upload RLS): identical to `AvatarStorageTests`'
    /// same-named test — the owner-folder segment MUST be the lowercased uid
    /// so it matches the write policy's `(storage.foldername(name))[1] =
    /// auth.uid()::text` (backend migration 20260715164057; Postgres
    /// `uuid::text` is lowercase, Foundation `UUID.uuidString` is UPPERCASE).
    /// This is the `trip-covers` sibling of the same 100%-reproducible bug,
    /// covering the own-photo (`TripFormView`) and Pexels (`CoverSearchSheet`)
    /// covers that both route through `CoverStorage.upload`.
    func testUploadFolderSegmentIsLowercasedToMatchRLSAuthUidText() async throws {
        let stub = StubCoverBucket()
        let userId = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))

        _ = try await CoverStorage.upload(Data([0x01]), for: userId, via: stub)

        let folder = String(try XCTUnwrap(try XCTUnwrap(stub.uploadedPath).split(separator: "/").first))
        XCTAssertEqual(folder, userId.uuidString.lowercased())
        XCTAssertNotEqual(folder, userId.uuidString, "an uppercase folder fails the RLS auth.uid()::text check")
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

    /// Job A hardening (P8b harden pass): the REPLACE flow — a row that
    /// already has a cover photo, then a second upload succeeds — must end
    /// up pointing at the NEW path, not the old one. Mirrors `TripFormView
    /// .uploadCoverPhoto`'s exact `coverImagePath = try await CoverStorage
    /// .upload(...)` assignment against a real (unattached) `Trip`, same
    /// shape as `testFailedUploadLeavesAnExistingTripsCoverImagePathUntouched`
    /// above but the SUCCESS side of that same scenario. Deliberately does
    /// NOT assert anything about the OLD object ever being deleted/cleaned
    /// up server-side — v1 orphans it on purpose (`CoverStorage`'s own doc
    /// comment, a `docs/BACKLOG.md` candidate); this only pins the ROW's own
    /// state, never a storage-bucket cleanup this app doesn't attempt.
    func testReplacingAnExistingCoverPhotoPointsTheRowAtTheNewPathNotTheOld() async throws {
        let stub = StubCoverBucket()
        let trip = TestFixtures.makeTrip(startDate: .now, endDate: .now.addingTimeInterval(86_400))
        let oldPath = "existing/old-cover.jpg"
        trip.coverImagePath = oldPath

        trip.coverImagePath = try await CoverStorage.upload(Data([0x02]), for: UUID(), via: stub)

        XCTAssertNotEqual(trip.coverImagePath, oldPath, "replace must move the row off the old path")
        XCTAssertEqual(trip.coverImagePath, stub.uploadedPath, "the row must point at exactly the path the upload wrote to")
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

    /// Job A hardening: a server row could plausibly send `""` instead of
    /// `null` for `cover_image_path` (`TripDTO.coverImagePath`'s additive/
    /// nullable contract says nothing about which one) — this pins the
    /// ACTUAL behavior rather than leaving it an unconfirmed assumption.
    /// `URL(string:)` happily parses a trailing-empty path segment, so
    /// `CoverImage.body`'s `if let coverImagePath, ...` guard treats `""` as
    /// "has a photo" (non-nil) and would attempt a real load against the
    /// bucket's own root rather than skipping straight to the gradient the
    /// way a genuine `nil` does. Not a crash, not a broken render —
    /// `CoverImage`'s gradient-first `ZStack` still shows through once that
    /// load fails (same `.empty`/`.failure`-renders-nothing contract every
    /// other photo miss already relies on) — just a wasted network attempt
    /// this documents rather than assumes away.
    func testPublicURLForEmptyStringPathIsNonNilRatherThanTreatedLikeNoPhoto() {
        let url = CoverStorage.publicURL(for: "")
        XCTAssertNotNil(url, "an empty path string still parses as a URL — CoverImage can't rely on nil to detect \"no photo\"")
        XCTAssertEqual(url?.absoluteString, "https://qgtveaqukvbtyunupzhn.supabase.co/storage/v1/object/public/trip-covers/")
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
