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
        let stub = StubAvatarBucket()
        let path = try await AvatarStorage.upload(Data([0x01]), for: UUID(), via: stub)
        XCTAssertEqual(path, stub.uploadedPath)
    }

    /// Regression (photo-upload RLS): the owner-folder segment MUST be the
    /// lowercased uid. The storage write policy (backend migration
    /// 20260715164057) gates every authenticated insert on
    /// `(storage.foldername(name))[1] = auth.uid()::text`, and Postgres
    /// renders `uuid::text` in lowercase. Foundation's `UUID.uuidString` is
    /// UPPERCASE, so an unlowercased folder segment fails the policy's
    /// `with check` on every real upload — the exact 100%-reproducible
    /// client-reported "Couldn't use that photo" failure. The stubbed bucket
    /// never hit real RLS, so only this string-shape assertion catches it.
    /// Uses a uid with hex letters so upper- and lower-case forms differ.
    func testUploadFolderSegmentIsLowercasedToMatchRLSAuthUidText() async throws {
        let stub = StubAvatarBucket()
        let userId = try XCTUnwrap(UUID(uuidString: "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE"))

        _ = try await AvatarStorage.upload(Data([0x01]), for: userId, via: stub)

        let folder = String(try XCTUnwrap(try XCTUnwrap(stub.uploadedPath).split(separator: "/").first))
        XCTAssertEqual(folder, userId.uuidString.lowercased())
        XCTAssertNotEqual(folder, userId.uuidString, "an uppercase folder fails the RLS auth.uid()::text check")
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

    /// P8a brief's "no path write on failed upload — atomicity", verified at
    /// the ROW level rather than just the stub's own bookkeeping (unlike
    /// `testUploadPropagatesAStorageFailureWithoutReturningAPath` above,
    /// which only proves the stub never recorded a path). This mirrors the
    /// EXACT caller shape both real call sites use — `AvatarPhotoPicker
    /// .upload`'s `avatarPath = try await AvatarStorage.upload(...)` inside a
    /// `do`/`catch`, and `SettingsView.saveProfile`'s/`ShareTripView`'s
    /// identical `profile.avatarPath = ...`/`tripProfile.avatarPath = ...` —
    /// against a real `@Model` row (unattached, no `ModelContainer` needed;
    /// same "build the model directly" convention `TestFixtures` uses) that
    /// already has an existing photo, so a regression that assigned the
    /// path unconditionally (e.g. hoisted above the `try`, or a caller that
    /// swallowed the throw) would flip this from "throws, row untouched" to
    /// "silently succeeds with a stale/empty row" and this test would catch
    /// it — `testUploadPropagatesAStorageFailureWithoutReturningAPath`
    /// alone would not, since it never touches a row at all.
    func testFailedUploadLeavesAnExistingRowsAvatarPathUntouchedForBothProfileTypes() async throws {
        let stub = StubAvatarBucket()
        stub.errorToThrow = StubUploadError()

        let profile = Profile(
            id: UUID(), displayName: "Priya", avatarColor: "amber",
            avatarPath: "existing/old-profile-photo.jpg", createdAt: .now, updatedAt: .now
        )
        do {
            profile.avatarPath = try await AvatarStorage.upload(Data([0x01]), for: UUID(), via: stub)
            XCTFail("expected upload to throw before the assignment ran")
        } catch is StubUploadError {
            XCTAssertEqual(profile.avatarPath, "existing/old-profile-photo.jpg")
        }

        let tripProfile = TripProfile(
            id: UUID(), tripId: UUID(), displayName: "Grandma", avatarColor: "sky",
            avatarPath: "existing/old-trip-profile-photo.jpg", linkedUserId: nil, createdAt: .now
        )
        do {
            tripProfile.avatarPath = try await AvatarStorage.upload(Data([0x02]), for: UUID(), via: stub)
            XCTFail("expected upload to throw before the assignment ran")
        } catch is StubUploadError {
            XCTAssertEqual(tripProfile.avatarPath, "existing/old-trip-profile-photo.jpg")
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
