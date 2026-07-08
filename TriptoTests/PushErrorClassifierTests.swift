import XCTest
import Supabase
@testable import Tripto

/// `PushErrorClassifier.classify` — SYNC_DESIGN.md's permanent-vs-transient
/// split, further split on the `.permanent` side into "rejected" (RLS/
/// constraint — retrying the exact same write can never succeed) vs
/// "exhausted" (an otherwise-transient error that ran out of retry budget —
/// the network may come back, so a *later* manual retry can still
/// succeed). `PushOutcome.permanent(retriable:)` carries that distinction
/// through to `SyncIssue`/`SyncIssuesSheet`'s "Try again."
final class PushErrorClassifierTests: XCTestCase {
    private struct StubError: Error, CustomStringConvertible {
        let description: String
    }

    func testRLSDenialIsPermanentAndNotRetriable() {
        let error = PostgrestError(code: "42501", message: "new row violates row-level security policy")
        let outcome = PushErrorClassifier.classify(error, attemptsSoFar: 0, maxAttempts: 8)
        guard case .permanent(_, let retriable) = outcome else {
            return XCTFail("expected .permanent, got \(outcome)")
        }
        XCTAssertFalse(retriable, "an RLS-denied write can never succeed on retry")
    }

    func testUniqueViolationIsPermanentAndNotRetriable() {
        let error = PostgrestError(code: "23505", message: "duplicate key value violates unique constraint")
        let outcome = PushErrorClassifier.classify(error, attemptsSoFar: 3, maxAttempts: 8)
        guard case .permanent(_, let retriable) = outcome else {
            return XCTFail("expected .permanent, got \(outcome)")
        }
        XCTAssertFalse(retriable, "a constraint violation can never succeed on retry")
    }

    func testHTTPForbiddenIsPermanentAndNotRetriable() {
        let response = HTTPURLResponse(url: URL(string: "https://example.com")!, statusCode: 403, httpVersion: nil, headerFields: nil)!
        let error = HTTPError(data: Data(), response: response)
        let outcome = PushErrorClassifier.classify(error, attemptsSoFar: 0, maxAttempts: 8)
        guard case .permanent(_, let retriable) = outcome else {
            return XCTFail("expected .permanent, got \(outcome)")
        }
        XCTAssertFalse(retriable, "an HTTP 403 rejection can never succeed on retry")
    }

    func testUnknownErrorAtBudgetExhaustionIsPermanentButRetriable() {
        let error = StubError(description: "connection reset")
        // attemptsSoFar + 1 == maxAttempts -> this attempt spends the budget.
        let outcome = PushErrorClassifier.classify(error, attemptsSoFar: 7, maxAttempts: 8)
        guard case .permanent(_, let retriable) = outcome else {
            return XCTFail("expected .permanent once the retry budget is spent, got \(outcome)")
        }
        XCTAssertTrue(retriable, "a budget-exhausted (not rejected) failure may still succeed if retried later")
    }

    func testUnknownErrorBelowBudgetIsTransient() {
        let error = StubError(description: "connection reset")
        let outcome = PushErrorClassifier.classify(error, attemptsSoFar: 2, maxAttempts: 8)
        guard case .transient = outcome else {
            return XCTFail("expected .transient while attempts remain, got \(outcome)")
        }
    }
}
