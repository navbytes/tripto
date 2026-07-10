import XCTest
@testable import Tripto

/// `SyncBackoff.delay` — the exponential-backoff-with-jitter shape shared by
/// `SyncEngine+Push.swift`'s push retry and `SyncEngine+Realtime.swift`'s
/// subscribe retry. Pure math, no `Task`/actor/network involved, so it's
/// tested directly rather than through either retry loop.
///
/// `SyncEngine+Realtime.swift`'s actual retry behavior (gating on
/// `isEffectivelyOffline`, bailing when a channel is superseded, the
/// recursive subscribe-attempt loop) is **not** covered here — it needs a
/// live or mocked `RealtimeChannelV2`/socket, and this codebase has no
/// realtime test double today. Left untested per the brief ("don't build a
/// mock realtime stack if it doesn't exist").
final class SyncBackoffTests: XCTestCase {
    func testFirstAttemptDelayIsSmallAndBounded() {
        for _ in 0..<20 {
            let delay = SyncBackoff.delay(attemptsSoFar: 0)
            XCTAssertGreaterThanOrEqual(delay, 1, "2^0 + jitter[0,1) must never be below 1s")
            XCTAssertLessThanOrEqual(delay, 2, "2^0 + jitter[0,1] must never exceed 2s")
        }
    }

    func testDelayGrowsExponentiallyBelowTheExponentCap() {
        let delay = SyncBackoff.delay(attemptsSoFar: 1)
        XCTAssertGreaterThanOrEqual(delay, 2)
        XCTAssertLessThanOrEqual(delay, 3)
    }

    /// The exponent clamps at `attemptsSoFar == 6` (2^6 = 64s), which is
    /// already past the default 60s cap — so every attempt from 6 onward
    /// deterministically saturates at the cap regardless of jitter, with no
    /// flakiness to guard against.
    func testDelaySaturatesAtTheDefaultCapOnceTheExponentClamps() {
        XCTAssertEqual(SyncBackoff.delay(attemptsSoFar: 6), 60)
        XCTAssertEqual(
            SyncBackoff.delay(attemptsSoFar: SyncEngine.maxPushAttempts), 60,
            "the last push retry (SyncEngine.maxPushAttempts) must still be capped"
        )
        XCTAssertEqual(SyncBackoff.delay(attemptsSoFar: 100), 60)
    }

    func testCustomCapIsRespected() {
        XCTAssertEqual(SyncBackoff.delay(attemptsSoFar: 10, cap: 5), 5)
    }

    /// `SyncEngine+Realtime.swift`'s subscribe-retry budget — bounded, and
    /// deliberately smaller than the push budget (SYNC_DESIGN.md: losing
    /// realtime degrades to pull-on-foreground, not lost data, so there's
    /// less to gain from a long tail of retries).
    func testRealtimeSubscribeRetryBudgetIsPositiveAndNoLargerThanPushBudget() {
        XCTAssertGreaterThan(SyncEngine.maxRealtimeSubscribeAttempts, 0)
        XCTAssertLessThanOrEqual(SyncEngine.maxRealtimeSubscribeAttempts, SyncEngine.maxPushAttempts)
    }
}
