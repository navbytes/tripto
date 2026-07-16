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

        func upload(_ path: String, data: Data, options: FileOptions) async throws {
            uploadedPath = path
            uploadedData = data
        }
    }

    private struct DownloadFailedError: Error {}

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
        XCTAssertTrue(uploadedPath.hasPrefix("\(userId.uuidString)/"), "must upload into the acting user's own folder")
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
