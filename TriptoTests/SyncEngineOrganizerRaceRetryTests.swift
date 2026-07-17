import Supabase
import XCTest
@testable import Tripto

/// F1 (structure review): `ShareTripView`'s view-local `withOrganizerRaceRetry`
/// moved onto `SyncEngine` (`SyncEngine+ShareLinks.swift`) specifically so
/// the retry policy itself — not just the two network calls it wraps — is
/// directly testable, via a synthetic `attempt` closure standing in for
/// `insertAndReadBack`. No PostgREST double exists in this codebase (see
/// `SyncEnginePushLoopTests`' own doc comment for why push/pull calls aren't
/// tested past the request-shaping stage either), so `createShareLink`/
/// `createInvite` themselves stay untested here — only the retry loop, which
/// needs no network at all.
final class SyncEngineOrganizerRaceRetryTests: XCTestCase {
    private func makeEngine() async -> SyncEngine {
        SyncEngine(modelContainer: AppSchema.makeContainer(inMemory: true), status: await SyncStatus(), forcedOnline: true)
    }

    private struct OtherError: Error {}

    func testSucceedsOnFirstAttemptWithoutRetrying() async throws {
        let engine = await makeEngine()
        var callCount = 0

        let result = try await engine.withOrganizerRaceRetry { () -> String in
            callCount += 1
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 1, "a successful first attempt must not retry")
    }

    func testANonPostgrestErrorPropagatesImmediatelyWithoutRetrying() async throws {
        let engine = await makeEngine()
        var callCount = 0

        do {
            _ = try await engine.withOrganizerRaceRetry {
                callCount += 1
                throw OtherError()
            }
            XCTFail("expected the error to propagate")
        } catch is OtherError {
            // Expected.
        }
        XCTAssertEqual(callCount, 1, "only a PostgrestError(code: 42501) is retried")
    }

    func testAPostgrestErrorWithADifferentCodePropagatesImmediatelyWithoutRetrying() async throws {
        let engine = await makeEngine()
        var callCount = 0

        do {
            _ = try await engine.withOrganizerRaceRetry {
                callCount += 1
                throw PostgrestError(code: "23505", message: "unique_violation")
            }
            XCTFail("expected the error to propagate")
        } catch let error as PostgrestError {
            XCTAssertEqual(error.code, "23505")
        }
        XCTAssertEqual(callCount, 1, "a non-42501 PostgrestError (e.g. a genuine constraint violation) must not retry")
    }

    /// The scenario this whole seam exists for: a brand-new trip's
    /// `trip_members` row hasn't landed yet, the first attempt 42501s, and a
    /// moment later (this test's stand-in for `SyncBackoff.delay`'s wait) it
    /// has — the one real (sub-2s) sleep this file spends, same "a short
    /// real delay is an acceptable cost for real coverage" precedent as this
    /// suite's other short waits.
    func testRetriesOnAnOrganizerRaceThenSucceeds() async throws {
        let engine = await makeEngine()
        var callCount = 0

        let result = try await engine.withOrganizerRaceRetry { () -> String in
            callCount += 1
            if callCount == 1 {
                throw PostgrestError(code: "42501", message: "insufficient_privilege")
            }
            return "ok"
        }

        XCTAssertEqual(result, "ok")
        XCTAssertEqual(callCount, 2, "the first organizer-race failure must be retried, not given up on")
    }
}
