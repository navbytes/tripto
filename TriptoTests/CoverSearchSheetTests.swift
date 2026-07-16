import CoreGraphics
import ImageIO
import Supabase
import UniformTypeIdentifiers
import XCTest
@testable import Tripto

/// `CoverSearchSheet` (P8c — Pexels cover search): response-model decoding,
/// debounce/min-length pure logic, error-message mapping, and the
/// download-then-upload pick pipeline. `TriptoTests` are hermetic (CLAUDE.md)
/// — every network seam here is a stub, mirroring `AvatarBucketUploading`'s
/// established pattern (`CoverStorageTests`/`AvatarStorageTests`).
final class CoverSearchSheetTests: XCTestCase {
    // MARK: - Response decode (fixture JSON, incl. missing-optional fields)

    /// The full shape `search-covers` actually returns (`~/repos/backend/
    /// projects/tripto/functions/search-covers/index.ts`'s own
    /// `TrimmedPhoto`/`SearchCoversResponse`) — plain camelCase, decoded with
    /// a bare `JSONDecoder` (no `JSONCoding` snake_case conversion, matching
    /// `Supa.invoke`'s own contract for Edge Function bodies).
    func testDecodesAFullResponseWithEveryFieldPresent() throws {
        let json = """
        {
          "photos": [
            {
              "id": 101,
              "alt": "Mountains at sunset",
              "photographerName": "Priya Rao",
              "photographerUrl": "https://pexels.com/@priya",
              "photoPageUrl": "https://pexels.com/photo/101",
              "src": {
                "large2x": "https://images.pexels.com/101/large2x.jpg",
                "large": "https://images.pexels.com/101/large.jpg",
                "medium": "https://images.pexels.com/101/medium.jpg"
              }
            }
          ],
          "page": 1,
          "totalResults": 42,
          "nextPage": true
        }
        """
        let response = try JSONDecoder().decode(CoverSearchResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.page, 1)
        XCTAssertEqual(response.totalResults, 42)
        XCTAssertTrue(response.nextPage)
        let photo = try XCTUnwrap(response.photos.first)
        XCTAssertEqual(photo.id, 101)
        XCTAssertEqual(photo.alt, "Mountains at sunset")
        XCTAssertEqual(photo.photographerName, "Priya Rao")
        XCTAssertEqual(photo.photographerUrl, "https://pexels.com/@priya")
        XCTAssertEqual(photo.photoPageUrl, "https://pexels.com/photo/101")
        XCTAssertEqual(photo.src.large2x, "https://images.pexels.com/101/large2x.jpg")
        XCTAssertEqual(photo.src.large, "https://images.pexels.com/101/large.jpg")
        XCTAssertEqual(photo.src.medium, "https://images.pexels.com/101/medium.jpg")
    }

    /// `alt`/`photographerUrl` outright OMITTED (not just `null`) — the
    /// defensive-optional case this app's own decode must tolerate even
    /// though the real function currently always sends both (defaulted to
    /// `""`, per that type's own doc comment) — a network response is never
    /// trusted to hold that assumption forever.
    func testDecodesWithAltAndPhotographerUrlKeysMissingEntirely() throws {
        let json = """
        {
          "photos": [
            {
              "id": 202,
              "photographerName": "Anon",
              "photoPageUrl": "https://pexels.com/photo/202",
              "src": { "large2x": "", "large": "", "medium": "" }
            }
          ],
          "page": 1,
          "totalResults": 0,
          "nextPage": false
        }
        """
        let response = try JSONDecoder().decode(CoverSearchResponse.self, from: Data(json.utf8))
        let photo = try XCTUnwrap(response.photos.first)
        XCTAssertNil(photo.alt)
        XCTAssertNil(photo.photographerUrl)
        XCTAssertFalse(response.nextPage)
    }

    /// An empty result page — `photos: []` must decode to an empty array,
    /// not throw or fail to find the key.
    func testDecodesAnEmptyPhotosArrayForNoResults() throws {
        let json = """
        { "photos": [], "page": 1, "totalResults": 0, "nextPage": false }
        """
        let response = try JSONDecoder().decode(CoverSearchResponse.self, from: Data(json.utf8))
        XCTAssertTrue(response.photos.isEmpty)
    }

    // MARK: - accessibleDescription (VoiceOver fallback for a nil/blank alt)

    func testAccessibleDescriptionFallsBackToPhotoWhenAltIsNil() {
        let photo = makePhoto(alt: nil)
        XCTAssertEqual(photo.accessibleDescription, "Photo")
    }

    func testAccessibleDescriptionFallsBackToPhotoWhenAltIsBlank() {
        let photo = makePhoto(alt: "   ")
        XCTAssertEqual(photo.accessibleDescription, "Photo")
    }

    func testAccessibleDescriptionUsesTrimmedAltWhenPresent() {
        let photo = makePhoto(alt: "  A quiet beach at dawn  ")
        XCTAssertEqual(photo.accessibleDescription, "A quiet beach at dawn")
    }

    // MARK: - shouldSearch / debounce (pure logic)

    func testShouldSearchFalseBelowMinimumLength() {
        XCTAssertFalse(CoverSearchSheet.shouldSearch(query: ""))
        XCTAssertFalse(CoverSearchSheet.shouldSearch(query: "a"))
    }

    func testShouldSearchTrueAtOrAboveMinimumLength() {
        XCTAssertTrue(CoverSearchSheet.shouldSearch(query: "ab"))
        XCTAssertTrue(CoverSearchSheet.shouldSearch(query: "mountains"))
    }

    func testShouldSearchTrimsWhitespaceBeforeCountingLength() {
        XCTAssertTrue(CoverSearchSheet.shouldSearch(query: "  ab  "))
        XCTAssertFalse(CoverSearchSheet.shouldSearch(query: "  a  "))
        XCTAssertFalse(CoverSearchSheet.shouldSearch(query: "   "))
    }

    /// The brief's own backstop: "don't hammer" the server rate limit — a
    /// regression that silently shrinks this back toward 0 loses the
    /// debounce entirely.
    func testDebounceIsAtLeastFourHundredMilliseconds() {
        XCTAssertGreaterThanOrEqual(CoverSearchSheet.debounceMilliseconds, 400)
    }

    // MARK: - friendlyMessage(for:) — mirrors `PasteImportSheetFriendlyMessageTests`

    func testFriendlyMessageForUnauthorizedMentionsSigningBackIn() {
        let message = CoverSearchSheet.friendlyMessage(for: FunctionsError.httpError(code: 401, data: Data()))
        XCTAssertTrue(message.contains("Sign back in"), "expected signed-out copy, got \(message)")
    }

    func testFriendlyMessageForRateLimitedMentionsTryingLater() {
        let message = CoverSearchSheet.friendlyMessage(for: FunctionsError.httpError(code: 429, data: Data()))
        XCTAssertTrue(message.contains("try again in an hour"), "expected rate-limited copy, got \(message)")
    }

    func testFriendlyMessageForPexelsUnavailableCodesMentionsPexels() {
        for code in [502, 503] {
            let message = CoverSearchSheet.friendlyMessage(for: FunctionsError.httpError(code: code, data: Data()))
            XCTAssertTrue(message.contains("Pexels"), "expected Pexels-unavailable copy for \(code), got \(message)")
        }
    }

    func testFriendlyMessageForOtherHttpCodesIsGenericTryAgain() {
        let message = CoverSearchSheet.friendlyMessage(for: FunctionsError.httpError(code: 400, data: Data()))
        XCTAssertEqual(message, "Something went wrong. Try again.")
    }

    func testFriendlyMessageForRelayErrorMentionsConnection() {
        let message = CoverSearchSheet.friendlyMessage(for: FunctionsError.relayError)
        XCTAssertTrue(message.contains("connection"), "expected connection copy, got \(message)")
    }

    /// Offline/non-`FunctionsError` fallback — same "never surface a raw
    /// technical error" contract `PasteImportSheet.friendlyMessage` pins.
    func testFriendlyMessageForNonFunctionsErrorFallsBackToConnectionCopy() {
        let message = CoverSearchSheet.friendlyMessage(for: URLError(.notConnectedToInternet))
        XCTAssertTrue(message.contains("connection"), "expected connection copy, got \(message)")
    }

    // MARK: - Stub search-provider seam ("stub protocol expected" — brief)

    private struct StubCoverSearchProvider: CoverSearchProviding, @unchecked Sendable {
        var response: CoverSearchResponse?
        var errorToThrow: Error?

        func search(query: String, page: Int) async throws -> CoverSearchResponse {
            if let errorToThrow { throw errorToThrow }
            return response ?? CoverSearchResponse(photos: [], page: page, totalResults: 0, nextPage: false)
        }
    }

    /// Exercises the `CoverSearchProviding` seam directly (no live network,
    /// no view harness) — proves a conforming stub can stand in for
    /// `SupabaseCoverSearchProvider` end to end: a caller passes `query`/
    /// `page` through and gets back exactly the canned response.
    func testStubSearchProviderReturnsItsCannedResponseForTheRequestedPage() async throws {
        let photo = makePhoto(id: 7)
        let canned = CoverSearchResponse(photos: [photo], page: 2, totalResults: 1, nextPage: false)
        let stub = StubCoverSearchProvider(response: canned)

        let result = try await stub.search(query: "beach", page: 2)
        XCTAssertEqual(result, canned)
    }

    func testStubSearchProviderPropagatesAThrownError() async throws {
        let stub = StubCoverSearchProvider(errorToThrow: FunctionsError.httpError(code: 429, data: Data()))
        do {
            _ = try await stub.search(query: "beach", page: 1)
            XCTFail("expected search to throw")
        } catch let FunctionsError.httpError(code, _) {
            XCTAssertEqual(code, 429)
        }
    }

    /// JOB A hardening: "a response with zero results renders the empty
    /// state not the error state." `content`'s own `case .loaded where
    /// photos.isEmpty` vs `.failed` switch is private/`@State`-bound (no
    /// SwiftUI-hosting harness in this suite to drive it directly — see the
    /// Tester report for the exact gap), but the switch's OWN input is fully
    /// determined by this seam: a successful response — even an empty one —
    /// must behave exactly like `testStubSearchProviderReturnsItsCanned
    /// ResponseForTheRequestedPage` above (returns normally), never like
    /// `testStubSearchProviderPropagatesAThrownError` (throws). Only an
    /// actual thrown error reaches `.failed`; an empty `photos` array is
    /// data, not an error.
    func testStubSearchProviderReturnsZeroResultsSuccessfullyRatherThanThrowing() async throws {
        let empty = CoverSearchResponse(photos: [], page: 1, totalResults: 0, nextPage: false)
        let stub = StubCoverSearchProvider(response: empty)

        let result = try await stub.search(query: "zzzznoresults", page: 1) // must not throw
        XCTAssertEqual(result, empty)
        XCTAssertTrue(result.photos.isEmpty)
    }

    /// JOB A hardening: "empty-query and 1-char query never invoke the
    /// provider." `shouldSearch` (already pinned above) IS the exact guard
    /// `.task(id: query)` checks before ever reaching `requestPage`/the
    /// provider — this ties that boundary directly to provider invocation
    /// (a call-counting stub) rather than just an abstract Bool, for the
    /// precise inputs the brief names plus their whitespace variants.
    /// `@MainActor`: `CoverSearchSheet` is a `View`, so `shouldSearch` (like
    /// every member of a `View`-conforming type) is MainActor-isolated —
    /// this is an `async` test method, unlike the plain synchronous
    /// `testShouldSearchFalseBelowMinimumLength` above, so it needs the
    /// explicit annotation to call it without a compiler warning.
    @MainActor
    func testShouldSearchGateStopsEmptyAndOneCharQueriesFromEverReachingTheProvider() async throws {
        final class CallCountingProvider: CoverSearchProviding, @unchecked Sendable {
            private(set) var callCount = 0
            func search(query: String, page: Int) async throws -> CoverSearchResponse {
                callCount += 1
                return CoverSearchResponse(photos: [], page: page, totalResults: 0, nextPage: false)
            }
        }
        let provider = CallCountingProvider()
        // Mirrors `.task(id: query)`'s own guard, verbatim: a caller checks
        // `shouldSearch` BEFORE ever reaching the provider, never after.
        for query in ["", "a", " ", " a ", "  "] where CoverSearchSheet.shouldSearch(query: query) {
            _ = try await provider.search(query: query, page: 1)
        }
        XCTAssertEqual(provider.callCount, 0, "empty/1-char/whitespace-only queries must never reach the search provider")
    }

    // MARK: - Task-cancellation contract (JOB A hardening): "rapid query
    // changes ... assert stale-query results never surface (task
    // cancellation actually cancels, not just ignores)." The real defense
    // lives in `CoverSearchSheet.body`'s `.task(id: query)` + `runSearch()`'s
    // own `guard !Task.isCancelled else { return }` right after `await
    // requestPage(1)` — both private/`@State`-bound, unreachable from
    // XCTest without a SwiftUI-hosting harness this codebase has never
    // needed (see the Tester report for the precise gap + the minimal
    // extraction that would close it). The end-to-end race — a real,
    // artificially slow query superseded by a real, fast one — IS covered,
    // at the UI-test level: `TriptoUITests
    // .testRapidQueryChangeNeverLetsAStaleSlowResultSurface`. This test
    // instead pins the one-level-down MECHANICAL contract that guard
    // depends on, directly against `CoverSearchProviding` with injected
    // latency: a `Task` cancelled before a slow provider call resolves must
    // still read `Task.isCancelled == true`, from INSIDE its own body, once
    // that call finally resumes — the exact position `runSearch`'s guard
    // checks from.

    private struct DelayedStubCoverSearchProvider: CoverSearchProviding, @unchecked Sendable {
        let response: CoverSearchResponse
        let delayMilliseconds: UInt64

        func search(query: String, page: Int) async throws -> CoverSearchResponse {
            try await Task.sleep(for: .milliseconds(delayMilliseconds))
            return response
        }
    }

    func testTaskCancelledBeforeASlowProviderCallResolvesStillReadsCancelledOnceItResumes() async throws {
        let stalePhoto = makePhoto(id: 1, photographerName: "Stale Query Result")
        let stub = DelayedStubCoverSearchProvider(
            response: CoverSearchResponse(photos: [stalePhoto], page: 1, totalResults: 1, nextPage: false),
            delayMilliseconds: 500
        )
        // Mirrors `runSearch`'s exact shape: `switch await requestPage(1) {
        // case .success: guard !Task.isCancelled else { return } ... }` —
        // "a newer query already superseded this one" (that guard's own
        // comment), reproduced with a REAL `Task` + REAL cancellation.
        let staleTask = Task<Bool, Never> {
            _ = try? await stub.search(query: "stale", page: 1)
            return Task.isCancelled
        }
        staleTask.cancel()
        let stillReadsCancelledAfterResuming = await staleTask.value
        XCTAssertTrue(
            stillReadsCancelledAfterResuming,
            "a task cancelled before a slow provider call resolves must still read cancelled once that call " +
                "resumes — the exact guard `runSearch`'s own `guard !Task.isCancelled else { return }` depends on"
        )
    }

    // MARK: - processAndUpload: the download -> process -> upload pipeline

    private struct StubDownloader: CoverPhotoDownloading, @unchecked Sendable {
        var dataToReturn: Data?
        var errorToThrow: Error?

        func data(from url: URL) async throws -> Data {
            if let errorToThrow { throw errorToThrow }
            guard let dataToReturn else { throw URLError(.badServerResponse) }
            return dataToReturn
        }
    }

    private final class StubUploadBucket: AvatarBucketUploading, @unchecked Sendable {
        private(set) var uploadedPath: String?
        private(set) var uploadedData: Data?
        /// JOB A hardening: the OTHER atomic-failure stage — set to make a
        /// successful download's own upload step fail.
        var errorToThrow: Error?

        func upload(_ path: String, data: Data, options: FileOptions) async throws {
            if let errorToThrow { throw errorToThrow }
            uploadedPath = path
            uploadedData = data
        }
    }

    private struct DownloadFailedError: Error {}
    private struct UploadFailedError: Error {}

    /// A minimal real, decodable image (PNG, deliberately not JPEG — proves
    /// the pipeline re-encodes regardless of source format, same reasoning
    /// as `ImageProcessingTests.makeTestImageData`) — needed because this
    /// path runs the REAL `ImageProcessing.downsampledJPEG`, not a stub.
    private func makeTestImageData(width: Int = 200, height: Int = 150) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return encoded as Data
    }

    /// End-to-end (hermetic): a stub download hands back real, decodable
    /// image bytes -> the REAL `ImageProcessing.downsampledJPEG` re-encodes
    /// them -> a stub upload bucket records the result. Proves the three
    /// pieces compose (this is the one thing none of `CoverStorageTests`/
    /// `ImageProcessingTests` individually cover), and that the returned
    /// credit pair is exactly the tapped photo's own.
    func testProcessAndUploadDownloadsProcessesAndUploadsThenReturnsThePathAndCredit() async throws {
        let downloader = StubDownloader(dataToReturn: makeTestImageData())
        let bucket = StubUploadBucket()
        let photo = makePhoto(
            id: 55, photographerName: "Ansel Adams", photographerUrl: "https://pexels.com/@ansel",
            photoPageUrl: "https://pexels.com/photo/55", large2x: "https://images.pexels.com/55/large2x.jpg"
        )
        let userId = UUID()

        let result = try await CoverSearchSheet.processAndUpload(
            photo, for: userId, downloader: downloader, uploadVia: bucket
        )

        XCTAssertEqual(result.creditName, "Ansel Adams")
        XCTAssertEqual(result.creditUrl, "https://pexels.com/photo/55")
        let uploadedPath = try XCTUnwrap(bucket.uploadedPath)
        XCTAssertEqual(result.path, uploadedPath)
        XCTAssertTrue(uploadedPath.hasPrefix("\(userId.uuidString.lowercased())/"), "must upload into the acting user's own folder (lowercased for RLS)")
        // Sanity: the uploaded bytes actually re-encoded to JPEG, confirming
        // the real `ImageProcessing.downsampledJPEG` ran, not a passthrough.
        let uploadedData = try XCTUnwrap(bucket.uploadedData)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(uploadedData as CFData, nil))
        XCTAssertEqual(CGImageSourceGetType(source) as String?, UTType.jpeg.identifier)
    }

    /// Prefers `large2x`; falls back to `large` only when `large2x` isn't a
    /// parseable URL (an empty string, in practice).
    func testProcessAndUploadFallsBackToLargeWhenLarge2xIsBlank() async throws {
        let downloader = StubDownloader(dataToReturn: makeTestImageData())
        let bucket = StubUploadBucket()
        let photo = makePhoto(large2x: "", large: "https://images.pexels.com/55/large.jpg")

        _ = try await CoverSearchSheet.processAndUpload(
            photo, for: UUID(), downloader: downloader, uploadVia: bucket
        )
        // No crash / no thrown error is the actual assertion here — a blank
        // `large2x` must not prevent the pipeline from trying `large`.
        XCTAssertNotNil(bucket.uploadedPath)
    }

    func testProcessAndUploadThrowsWhenNeitherSourceUrlIsUsable() async throws {
        let downloader = StubDownloader(dataToReturn: makeTestImageData())
        let bucket = StubUploadBucket()
        let photo = makePhoto(large2x: "", large: "")

        do {
            _ = try await CoverSearchSheet.processAndUpload(photo, for: UUID(), downloader: downloader, uploadVia: bucket)
            XCTFail("expected processAndUpload to throw")
        } catch let error as CoverSearchError {
            XCTAssertEqual(error, .noUsableImageURL)
        }
        XCTAssertNil(bucket.uploadedPath, "must never upload anything when no source URL was usable")
    }

    /// Atomic (same contract `CoverStorage.upload` itself documents): a
    /// failed download must never reach the upload step at all.
    func testProcessAndUploadPropagatesADownloadFailureWithoutUploadingAnything() async throws {
        let downloader = StubDownloader(errorToThrow: DownloadFailedError())
        let bucket = StubUploadBucket()
        let photo = makePhoto()

        do {
            _ = try await CoverSearchSheet.processAndUpload(photo, for: UUID(), downloader: downloader, uploadVia: bucket)
            XCTFail("expected processAndUpload to throw")
        } catch is DownloadFailedError {
            // Expected.
        }
        XCTAssertNil(bucket.uploadedPath)
    }

    /// JOB A hardening: the OTHER half of "pick-flow failure at the DOWNLOAD
    /// stage vs the UPLOAD stage" — a successful download whose upload then
    /// fails must equally throw and produce no result. `CoverSearchSheet
    /// .pick()`'s own `do` block only calls `onPick(result.path, ...)` —
    /// the one place `TripFormView`'s draft `coverImagePath`/
    /// `coverCreditName`/`coverCreditUrl` ever change — past a fully
    /// successful `processAndUpload` (see that method's own "atomic" doc
    /// comment); its `catch` only sets a toast. Proving this throws is
    /// therefore equivalent to proving the draft stays byte-for-byte
    /// untouched: there is no code path where `onPick` runs with a partial
    /// result.
    func testProcessAndUploadPropagatesAnUploadFailureAfterASuccessfulDownload() async throws {
        let downloader = StubDownloader(dataToReturn: makeTestImageData())
        let bucket = StubUploadBucket()
        bucket.errorToThrow = UploadFailedError()
        let photo = makePhoto()

        do {
            _ = try await CoverSearchSheet.processAndUpload(photo, for: UUID(), downloader: downloader, uploadVia: bucket)
            XCTFail("expected processAndUpload to throw")
        } catch is UploadFailedError {
            // Expected.
        }
        XCTAssertNil(bucket.uploadedPath, "a thrown upload must never be recorded as though it had succeeded")
        XCTAssertNil(bucket.uploadedData)
    }

    // MARK: - D1 (fix round): trust boundary — only images.pexels.com, only https

    func testProcessAndUploadThrowsWhenLarge2xHostIsNotImagesPexelsCom() async throws {
        let downloader = StubDownloader(dataToReturn: makeTestImageData())
        let bucket = StubUploadBucket()
        // Syntactically valid (so the pre-D1 fallback would have "won" on
        // this candidate alone) but an untrusted host — must still throw
        // rather than fetch/upload it, even though `large` below is fine.
        let photo = makePhoto(large2x: "https://evil.example.com/1.jpg", large: "https://images.pexels.com/1/large.jpg")

        do {
            _ = try await CoverSearchSheet.processAndUpload(photo, for: UUID(), downloader: downloader, uploadVia: bucket)
            XCTFail("expected processAndUpload to throw for an untrusted host")
        } catch let error as CoverSearchError {
            XCTAssertEqual(error, .noUsableImageURL)
        }
        XCTAssertNil(bucket.uploadedPath, "must never download/upload from an untrusted host")
    }

    func testProcessAndUploadThrowsWhenSchemeIsNotHttps() async throws {
        let downloader = StubDownloader(dataToReturn: makeTestImageData())
        let bucket = StubUploadBucket()
        let photo = makePhoto(large2x: "http://images.pexels.com/1/large2x.jpg", large: "")

        do {
            _ = try await CoverSearchSheet.processAndUpload(photo, for: UUID(), downloader: downloader, uploadVia: bucket)
            XCTFail("expected processAndUpload to throw for a non-https scheme")
        } catch let error as CoverSearchError {
            XCTAssertEqual(error, .noUsableImageURL)
        }
        XCTAssertNil(bucket.uploadedPath)
    }

    // MARK: - D2 (fix round): searchApplication / loadMoreApplication — the
    // race where "Show more" for query A resolves after the user has
    // already retyped to query B.

    func testSearchApplicationAlwaysResetsToPageOneOnSuccess() {
        let photo = makePhoto(id: 9)
        let response = CoverSearchResponse(photos: [photo], page: 1, totalResults: 1, nextPage: true)

        let application = CoverSearchSheet.searchApplication(for: .success(response))

        XCTAssertEqual(application.currentPage, 1, "a fresh search's result is always page 1, even after loadMore advanced it")
        XCTAssertEqual(application.photos, [photo])
        XCTAssertTrue(application.hasNextPage)
        XCTAssertEqual(application.state, .loaded)
    }

    func testSearchApplicationResetsToPageOneAndClearsPhotosOnFailureToo() {
        let application = CoverSearchSheet.searchApplication(for: .failure("offline"))

        XCTAssertEqual(application.currentPage, 1)
        XCTAssertTrue(application.photos.isEmpty)
        XCTAssertFalse(application.hasNextPage)
        XCTAssertEqual(application.state, .failed("offline"))
    }

    func testLoadMoreApplicationAppendsAndAdvancesPageWhenQueryUnchanged() throws {
        let existing = [makePhoto(id: 1)]
        let newPhoto = makePhoto(id: 2)
        let response = CoverSearchResponse(photos: [newPhoto], page: 2, totalResults: 2, nextPage: false)

        let application = try XCTUnwrap(CoverSearchSheet.loadMoreApplication(
            outcome: .success(response), issuedForQuery: "beach", liveQuery: "beach",
            existingPhotos: existing, existingPage: 1
        ))

        XCTAssertEqual(application.photos, existing + [newPhoto])
        XCTAssertEqual(application.currentPage, 2)
        XCTAssertFalse(application.hasNextPage)
        XCTAssertNil(application.loadMoreError)
    }

    /// The core D2 invariant: a page fetch issued for one query, resolving
    /// after the live query has changed, must produce `nil` — the caller
    /// then leaves `photos`/`currentPage` completely untouched, so the old
    /// query's page can never append onto the new query's results.
    func testLoadMoreApplicationIsNilWhenQueryChangedMidFlightSoTheOldPageNeverAppends() {
        let existing = [makePhoto(id: 1)]
        let staleResponse = CoverSearchResponse(photos: [makePhoto(id: 999)], page: 2, totalResults: 2, nextPage: false)

        let application = CoverSearchSheet.loadMoreApplication(
            outcome: .success(staleResponse), issuedForQuery: "beach", liveQuery: "mountain",
            existingPhotos: existing, existingPage: 1
        )

        XCTAssertNil(application, "a page resolved for a superseded query must never be applied")
    }

    /// Same bail, on the failure branch — a stale error must not clobber
    /// whatever the new query's own search already put on screen either.
    func testLoadMoreApplicationIsNilWhenQueryChangedMidFlightEvenOnFailure() {
        let application = CoverSearchSheet.loadMoreApplication(
            outcome: .failure("stale error"), issuedForQuery: "beach", liveQuery: "mountain",
            existingPhotos: [makePhoto(id: 1)], existingPage: 1
        )
        XCTAssertNil(application)
    }

    func testLoadMoreApplicationSurfacesTheErrorAndKeepsHasNextPageWhenQueryUnchanged() throws {
        let existing = [makePhoto(id: 1)]
        let application = try XCTUnwrap(CoverSearchSheet.loadMoreApplication(
            outcome: .failure("Couldn\u{2019}t reach Pexels right now. Try again."), issuedForQuery: "beach", liveQuery: "beach",
            existingPhotos: existing, existingPage: 1
        ))

        XCTAssertEqual(application.photos, existing, "a failed page fetch must not lose the results already on screen")
        XCTAssertEqual(application.currentPage, 1, "an unadvanced page number — nothing new actually loaded")
        XCTAssertTrue(application.hasNextPage, "still offer retry — the failure doesn't mean there's no next page")
        XCTAssertEqual(application.loadMoreError, "Couldn\u{2019}t reach Pexels right now. Try again.")
    }

    // MARK: - D4 (fix round): blank photographerName omits the caption line

    func testHasPhotographerCreditFalseWhenNameIsBlank() {
        XCTAssertFalse(makePhoto(photographerName: "").hasPhotographerCredit)
    }

    func testHasPhotographerCreditFalseWhenNameIsWhitespaceOnly() {
        XCTAssertFalse(makePhoto(photographerName: "   ").hasPhotographerCredit)
    }

    func testHasPhotographerCreditTrueWhenNamePresent() {
        XCTAssertTrue(makePhoto(photographerName: "Priya Rao").hasPhotographerCredit)
    }

    // MARK: - Fixtures

    private func makePhoto(
        id: Int = 1, alt: String? = "A photo", photographerName: String = "Someone",
        photographerUrl: String? = "https://pexels.com/@someone", photoPageUrl: String = "https://pexels.com/photo/1",
        large2x: String = "https://images.pexels.com/1/large2x.jpg", large: String = "https://images.pexels.com/1/large.jpg",
        medium: String = "https://images.pexels.com/1/medium.jpg"
    ) -> CoverSearchResponse.Photo {
        CoverSearchResponse.Photo(
            id: id, alt: alt, photographerName: photographerName, photographerUrl: photographerUrl,
            photoPageUrl: photoPageUrl, src: .init(large2x: large2x, large: large, medium: medium)
        )
    }
}
