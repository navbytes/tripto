import Supabase
import XCTest
@testable import Tripto

/// `PasteImportSheet.friendlyMessage(for:)` — the `ingest-text` status-code
/// mapping (400/401/404/502/default), `FunctionsError.relayError`, and the
/// non-`FunctionsError` fallback branch. Mirrors `SignInFailureMessageTests`'
/// pure-function style.
final class PasteImportSheetFriendlyMessageTests: XCTestCase {
    private struct OtherDomainError: Error {}

    func testHTTP400ReturnsInvalidTextCopy() {
        let error = FunctionsError.httpError(code: 400, data: Data())
        let message = PasteImportSheet.friendlyMessage(for: error)
        XCTAssertTrue(message.contains("valid text"), "expected invalid-text copy, got \(message)")
    }

    func testHTTP401ReturnsSignedOutCopy() {
        let error = FunctionsError.httpError(code: 401, data: Data())
        let message = PasteImportSheet.friendlyMessage(for: error)
        XCTAssertTrue(message.contains("signed out"), "expected signed-out copy, got \(message)")
    }

    func testHTTP404ReturnsCouldNotAccessTripCopy() {
        let error = FunctionsError.httpError(code: 404, data: Data())
        let message = PasteImportSheet.friendlyMessage(for: error)
        XCTAssertTrue(message.contains("access that trip"), "expected trip-access copy, got \(message)")
    }

    func testHTTP502ReturnsCouldNotProcessCopy() {
        let error = FunctionsError.httpError(code: 502, data: Data())
        let message = PasteImportSheet.friendlyMessage(for: error)
        XCTAssertTrue(message.contains("Couldn\u{2019}t process"), "expected couldn't-process copy, got \(message)")
    }

    /// B1 (`docs/BACKLOG.md`): backend's `ingest-text` rate limit lands
    /// separately (`text_import_events`, 20/hr default) — this is just the
    /// client-side friendly-message mapping for the 429 it returns.
    func testHTTP429ReturnsRateLimitedCopy() {
        let error = FunctionsError.httpError(code: 429, data: Data())
        let message = PasteImportSheet.friendlyMessage(for: error)
        XCTAssertTrue(message.contains("try again in an hour"), "expected rate-limited copy, got \(message)")
    }

    func testOtherHTTPCodesReturnGenericTryAgainCopy() {
        let codes = [403, 500, 503]
        for code in codes {
            let error = FunctionsError.httpError(code: code, data: Data())
            let message = PasteImportSheet.friendlyMessage(for: error)
            XCTAssertEqual(message, "Something went wrong. Try again.", "expected generic copy for \(code), got \(message)")
        }
    }

    func testRelayErrorReturnsConnectionCopy() {
        let message = PasteImportSheet.friendlyMessage(for: FunctionsError.relayError)
        XCTAssertTrue(message.contains("connection"), "expected connection copy, got \(message)")
    }

    func testNonFunctionsErrorFallsBackToConnectionCopy() {
        // Exercises the `guard let functionsError = error as? FunctionsError`
        // fallback — any error type never surfaced by `Supa.invoke` (e.g. a
        // raw `URLError`) should still get friendly copy, not propagate a
        // technical description.
        let message = PasteImportSheet.friendlyMessage(for: URLError(.notConnectedToInternet))
        XCTAssertTrue(message.contains("connection"), "expected connection copy, got \(message)")
    }

    func testOtherDomainErrorFallsBackToConnectionCopy() {
        let message = PasteImportSheet.friendlyMessage(for: OtherDomainError())
        XCTAssertTrue(message.contains("connection"), "expected connection copy, got \(message)")
    }
}
