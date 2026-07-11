import XCTest
@testable import Tripto

/// PLAN-signature-layer.md §D3's boarding-pass physicality — the pure math
/// (tear threshold/progress, tilt clamp, travel-day trigger) plus the
/// torn-stub persistence helper. No view/gesture code here on purpose
/// (`BookingDetailView` owns that); everything below is a deterministic
/// function of its inputs.
final class PassEffectsTests: XCTestCase {
    // MARK: - Tear progress/threshold (the plan's explicit "pure function
    // with unit tests" ask)

    func testTearProgressIsZeroAtRest() {
        XCTAssertEqual(PassEffects.tearProgress(translation: 0), 0)
    }

    func testTearProgressIsHalfAtHalfTheThreshold() {
        XCTAssertEqual(PassEffects.tearProgress(translation: PassEffects.tearThreshold / 2), 0.5, accuracy: 0.0001)
    }

    func testTearProgressIsOneExactlyAtTheThreshold() {
        XCTAssertEqual(PassEffects.tearProgress(translation: PassEffects.tearThreshold), 1, accuracy: 0.0001)
    }

    /// A drag back toward (or past) the leading anchor never "un-tears" —
    /// a real perforation doesn't reverse.
    func testTearProgressFloorsAtZeroForNegativeTranslation() {
        XCTAssertEqual(PassEffects.tearProgress(translation: -40), 0)
    }

    func testHasReachedDetachThresholdExactlyAtNinetySixPoints() {
        XCTAssertTrue(PassEffects.hasReachedDetachThreshold(translation: PassEffects.tearThreshold))
    }

    func testHasReachedDetachThresholdFalseJustBelowThreshold() {
        XCTAssertFalse(PassEffects.hasReachedDetachThreshold(translation: PassEffects.tearThreshold - 1))
    }

    func testHasReachedDetachThresholdTrueWellPastThreshold() {
        XCTAssertTrue(PassEffects.hasReachedDetachThreshold(translation: PassEffects.tearThreshold + 200))
    }

    /// The two haptic-tick fractions from the plan (30%/60%) actually land
    /// where `BookingDetailView`'s drag handler compares `tearProgress`
    /// against — pins the constants, not just their existence.
    func testTickFractionsMatchThirtyAndSixtyPercentOfThreshold() {
        let thirtyPercentTranslation = PassEffects.tearThreshold * 0.3
        let sixtyPercentTranslation = PassEffects.tearThreshold * 0.6
        XCTAssertGreaterThanOrEqual(
            PassEffects.tearProgress(translation: thirtyPercentTranslation), PassEffects.tearTick30Progress
        )
        XCTAssertLessThan(
            PassEffects.tearProgress(translation: thirtyPercentTranslation - 5), PassEffects.tearTick30Progress
        )
        XCTAssertGreaterThanOrEqual(
            PassEffects.tearProgress(translation: sixtyPercentTranslation), PassEffects.tearTick60Progress
        )
        XCTAssertLessThan(
            PassEffects.tearProgress(translation: sixtyPercentTranslation - 5), PassEffects.tearTick60Progress
        )
    }

    func testTearOffsetXAppliesTheRubberBand() {
        XCTAssertEqual(PassEffects.tearOffsetX(translation: PassEffects.tearThreshold), 48) // 96 * 0.5
    }

    func testTearOffsetXClampsNegativeTranslationToZero() {
        XCTAssertEqual(PassEffects.tearOffsetX(translation: -60), 0)
    }

    func testTearRotationDegreesScalesLinearlyBeforeTheThreshold() {
        let halfway = PassEffects.tearRotationDegrees(translation: PassEffects.tearThreshold / 2)
        XCTAssertEqual(halfway, PassEffects.tearMaxRotationDegrees / 2, accuracy: 0.0001)
    }

    /// "Rotation ≤6°" holds even for a big over-drag before release.
    func testTearRotationDegreesNeverExceedsTheMaxPastTheThreshold() {
        XCTAssertEqual(PassEffects.tearRotationDegrees(translation: PassEffects.tearThreshold * 5), PassEffects.tearMaxRotationDegrees)
    }

    // MARK: - Dashed-rule gap ("the dash gap visually opens")

    /// At rest (progress 0) the gap must equal the pass's original literal
    /// `dash: [5, 4]` — the §6.5 "zero visual change beyond the tilt"
    /// guarantee for every non-travel-day/non-flight item.
    func testDashGapWidthAtRestMatchesTheOriginalConstant() {
        XCTAssertEqual(PassEffects.dashGapWidth(progress: 0), 4)
    }

    func testDashGapWidthWidensToItsMaxAtFullTear() {
        XCTAssertEqual(PassEffects.dashGapWidth(progress: 1), 20)
    }

    func testDashGapWidthClampsProgressAboveOne() {
        XCTAssertEqual(PassEffects.dashGapWidth(progress: 2.5), PassEffects.dashGapWidth(progress: 1))
    }

    // MARK: - Scroll tilt (±3° hard cap)

    func testTiltDegreesIsZeroAtRest() {
        XCTAssertEqual(PassEffects.tiltDegrees(minY: 0), 0)
    }

    func testTiltDegreesClampsToThePositiveMax() {
        XCTAssertEqual(PassEffects.tiltDegrees(minY: 10_000), PassEffects.maxTiltDegrees)
    }

    func testTiltDegreesClampsToTheNegativeMax() {
        XCTAssertEqual(PassEffects.tiltDegrees(minY: -10_000), -PassEffects.maxTiltDegrees)
    }

    // MARK: - Travel-day trigger

    private func utcNoon(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day; components.hour = 12
        return utc.date(from: components)!
    }

    func testIsTravelDayTrueForAFlightStartingToday() {
        let item = TestFixtures.makeItineraryItem(category: .flight, startsAt: utcNoon(2026, 5, 14), tz: "UTC")
        XCTAssertTrue(PassEffects.isTravelDay(item: item, today: DayDate(year: 2026, month: 5, day: 14)))
    }

    /// Flights only — same-day hotel/activity/etc. never gets the pill or
    /// the drag-interactive stub.
    func testIsTravelDayFalseForNonFlightCategoryOnTheSameDay() {
        let item = TestFixtures.makeItineraryItem(category: .hotel, startsAt: utcNoon(2026, 5, 14), tz: "UTC")
        XCTAssertFalse(PassEffects.isTravelDay(item: item, today: DayDate(year: 2026, month: 5, day: 14)))
    }

    func testIsTravelDayFalseWhenTodayIsADifferentDay() {
        let item = TestFixtures.makeItineraryItem(category: .flight, startsAt: utcNoon(2026, 5, 14), tz: "UTC")
        XCTAssertFalse(PassEffects.isTravelDay(item: item, today: DayDate(year: 2026, month: 5, day: 15)))
    }

    /// The comparison must use the flight's own zone, not the device's —
    /// a late-evening New York departure that's already "tomorrow" UTC is
    /// still today's travel day in New York.
    func testIsTravelDayUsesTheItemsOwnZoneNotUTC() {
        let newYork = TimeZone(identifier: "America/New_York")!
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = newYork
        var components = DateComponents()
        components.year = 2026; components.month = 5; components.day = 14; components.hour = 23; components.minute = 30
        let lateDeparture = nyCalendar.date(from: components)! // = 2026-05-15 03:30 UTC
        let item = TestFixtures.makeItineraryItem(category: .flight, startsAt: lateDeparture, tz: "America/New_York")
        XCTAssertTrue(PassEffects.isTravelDay(item: item, today: DayDate(year: 2026, month: 5, day: 14)))
        XCTAssertFalse(PassEffects.isTravelDay(item: item, today: DayDate(year: 2026, month: 5, day: 15)))
    }

    // MARK: - Torn-stub persistence

    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "PassEffectsTests")
        defaults.removePersistentDomain(forName: "PassEffectsTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "PassEffectsTests")
        defaults = nil
        super.tearDown()
    }

    func testTornStubDefaultsToFalseForAKeyThatWasNeverSet() {
        XCTAssertFalse(PassEffects.isTornStub(itemId: UUID(), day: DayDate(year: 2026, month: 5, day: 14), defaults: defaults))
    }

    func testTornStubRoundTripsThroughSetAndGet() {
        let itemId = UUID()
        let day = DayDate(year: 2026, month: 5, day: 14)
        PassEffects.setTornStub(true, itemId: itemId, day: day, defaults: defaults)
        XCTAssertTrue(PassEffects.isTornStub(itemId: itemId, day: day, defaults: defaults))
    }

    /// "Resets the next day": the persisted key is scoped to item+day, so a
    /// new day is simply a key that was never set — nothing to clean up.
    func testTornStubDoesNotCarryOverToADifferentDay() {
        let itemId = UUID()
        PassEffects.setTornStub(true, itemId: itemId, day: DayDate(year: 2026, month: 5, day: 14), defaults: defaults)
        XCTAssertFalse(PassEffects.isTornStub(itemId: itemId, day: DayDate(year: 2026, month: 5, day: 15), defaults: defaults))
    }

    func testTornStubIsScopedPerItemNotSharedAcrossItems() {
        let day = DayDate(year: 2026, month: 5, day: 14)
        PassEffects.setTornStub(true, itemId: UUID(), day: day, defaults: defaults)
        XCTAssertFalse(PassEffects.isTornStub(itemId: UUID(), day: day, defaults: defaults))
    }
}
