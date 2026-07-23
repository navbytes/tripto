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

    // MARK: - Job A hardening (P8b harden pass): HeroFlightModel.State
    // .flying threading — P5's register-mismatch class, extended to P8b's
    // cover fields. Nothing in this suite ever constructed a `.flying` case
    // before; these are the first unit-level pin that the associated values
    // a tapped card hands off (`HomeView.openTrip`) survive into whatever
    // renders the flight clone, without a live view hierarchy.

    /// P5 fix-round item 12 threaded `register` through this case's
    /// associated values so `HeroFlightClone` renders the SAME
    /// register-specific content (`FirstUpStrip`/`TodayPanelView`/plain) the
    /// tapped card did — but no test ever pinned that at the unit level,
    /// only visually. This closes that gap for `register`, and extends it to
    /// `coverImagePath`/`coverGradient`: those two ride for free today (the
    /// case holds the SAME `Trip` reference `TripCard` itself renders, not a
    /// copy — `HeroFlightClone.body`'s `CoverImage(coverGradientKey: trip
    /// .coverGradient, coverImagePath: trip.coverImagePath)` reads straight
    /// off it), but that's a property of the CURRENT shape, not something
    /// the compiler enforces. A future refactor toward a `Sendable`
    /// snapshot/DTO here (a plausible motivation for an `@Observable
    /// @MainActor` model) could silently drop a field the exact same way
    /// `register` was once missing — this pins the contract now, at the one
    /// point such a regression would first appear.
    func testFlyingStateCarriesTheTappedTripsOwnCoverFieldsAndRegisterRatherThanACopyOrDefault() throws {
        let trip = TestFixtures.makeTrip(startDate: .now, endDate: .now.addingTimeInterval(86_400 * 5))
        trip.coverGradient = "plum"
        trip.coverImagePath = "abc-123/def-456.jpg"
        let sourceFrame = CGRect(x: 0, y: 62, width: 402, height: 151)

        let state = HeroFlightModel.State.flying(
            trip: trip, people: [], isPending: false, register: .plain, today: .now, sourceFrame: sourceFrame
        )

        guard case .flying(let flownTrip, _, _, let flownRegister, _, let flownSourceFrame) = state else {
            return XCTFail("expected .flying")
        }
        XCTAssertTrue(flownTrip === trip, "must carry the SAME Trip reference the card rendered, never a copy")
        XCTAssertEqual(flownTrip.coverImagePath, "abc-123/def-456.jpg")
        XCTAssertEqual(flownTrip.coverGradient, "plum")
        XCTAssertEqual(flownRegister, .plain)
        XCTAssertEqual(flownSourceFrame, sourceFrame)
    }

    /// The `.next`/`.now` registers carry their OWN associated payload
    /// (`HomeFirstUp?`/`HomeTodayPanel`) — confirms a non-`.plain` register
    /// (and a trip with NO photo, the far more common real case today) also
    /// threads through intact, not just the simplest `.plain` case above.
    func testFlyingStateCarriesANonPlainRegisterAndANilCoverPathIntact() throws {
        let trip = TestFixtures.makeTrip(startDate: .now, endDate: .now.addingTimeInterval(86_400 * 5))
        XCTAssertNil(trip.coverImagePath, "sanity: a brand-new fixture trip has no photo")

        let state = HeroFlightModel.State.flying(
            trip: trip, people: [], isPending: true, register: .next(firstUp: nil), today: .now,
            sourceFrame: .zero
        )

        guard case .flying(let flownTrip, _, let flownIsPending, let flownRegister, _, _) = state else {
            return XCTFail("expected .flying")
        }
        XCTAssertNil(flownTrip.coverImagePath)
        XCTAssertEqual(flownRegister, .next(firstUp: nil))
        XCTAssertTrue(flownIsPending)
    }
}
