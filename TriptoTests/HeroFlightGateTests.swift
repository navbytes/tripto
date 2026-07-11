import XCTest
import SwiftUI
@testable import Tripto

/// `HeroFlightGate` (PLAN-signature-layer.md §D1 point 7) — split out
/// precisely so the RM/AX/missing-frame fallback table is unit-testable
/// without a live view hierarchy (see its own doc comment); this pins that
/// table plus the review should-fix's timing invariants for
/// `HeroFlight.destFrameTimeout`/`totalLifetimeWatchdog` (the watchdog
/// itself is an unconditional side-effecting timer, not a decision
/// function, so there's nothing further to extract into `HeroFlightGate`
/// for it — this is the regression net instead).
final class HeroFlightGateTests: XCTestCase {
    // MARK: - shouldFly

    func testFliesWithNoBarriers() {
        XCTAssertTrue(HeroFlightGate.shouldFly(reduceMotion: false, isAccessibilitySize: false, hasSourceFrame: true))
    }

    func testReduceMotionFallsBackToPlainPush() {
        XCTAssertFalse(HeroFlightGate.shouldFly(reduceMotion: true, isAccessibilitySize: false, hasSourceFrame: true))
    }

    func testAccessibilitySizeFallsBackToPlainPush() {
        XCTAssertFalse(HeroFlightGate.shouldFly(reduceMotion: false, isAccessibilitySize: true, hasSourceFrame: true))
    }

    func testMissingSourceFrameFallsBackToPlainPush() {
        XCTAssertFalse(HeroFlightGate.shouldFly(reduceMotion: false, isAccessibilitySize: false, hasSourceFrame: false))
    }

    // MARK: - isPlausibleDestFrame

    func testRejectsTransientPreLayoutFrame() {
        // Real captured trace from `isPlausibleDestFrame`'s own doc comment:
        // TripHeroView's first report, before it settles into its real
        // placed position one layout pass later.
        XCTAssertFalse(HeroFlightGate.isPlausibleDestFrame(CGRect(x: -201, y: -437, width: 402, height: 151)))
    }

    func testAcceptsRealPlacedFrame() {
        XCTAssertTrue(HeroFlightGate.isPlausibleDestFrame(CGRect(x: 0, y: 62, width: 402, height: 151)))
    }

    func testRejectsZeroSizeFrame() {
        XCTAssertFalse(HeroFlightGate.isPlausibleDestFrame(.zero))
    }

    // MARK: - Touch-block hardening timing invariants (review should-fix)

    /// The unconditional watchdog must comfortably outlast the happy path's
    /// full flight settle time, or a future "tune" could clip a legitimate
    /// in-flight animation instead of only catching a stuck one.
    func testWatchdogOutlastsHappyPathFlightDuration() {
        XCTAssertGreaterThan(HeroFlight.totalLifetimeWatchdog, HeroFlight.duration)
    }

    /// The watchdog is a strict superset ceiling over the pre-flight
    /// handshake timeout, never a tighter one that could race it.
    func testWatchdogOutlastsDestFrameTimeout() {
        XCTAssertGreaterThan(HeroFlight.totalLifetimeWatchdog, HeroFlight.destFrameTimeout)
    }
}
