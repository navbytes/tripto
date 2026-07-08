import XCTest
@testable import Tripto

/// `ItineraryTimeZone.localDay` bucketing across a UTC calendar-day
/// boundary (BUILD_PLAN.md §7.4; ACCEPTANCE.md "(a)") — the exact case
/// `ItineraryDayBucketing`'s doc comment calls out as "directly unit
/// testable regardless of the machine running them." Every crossing case
/// here deliberately produces a genuine UTC-vs-local date mismatch (not
/// just a same-day sanity check), so a regression that swapped in
/// UTC-based or `Calendar.current`-based bucketing would actually fail.
final class ItineraryTimeZoneTests: XCTestCase {
    private let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return utc.date(from: components)!
    }

    /// A 23:30 New York evening (EDT, UTC-4) is already 03:30 UTC the
    /// *next* calendar day — `localDay` must still report the evening's own
    /// New York date, not the UTC date the instant technically falls on.
    func testLateEveningStaysOnItsOwnLocalDateDespiteUTCAlreadyRollingToTheNextDay() {
        let instant = utcInstant(2026, 5, 15, 3, 30) // = 2026-05-14 23:30 EDT
        let day = ItineraryTimeZone.localDay(of: instant, in: newYork)
        XCTAssertEqual(day, DayDate(year: 2026, month: 5, day: 14))
    }

    /// A 00:30 Lisbon (WEST, UTC+1) instant is still 23:30 UTC the
    /// *previous* calendar day — `localDay` must report the new Lisbon date
    /// the traveler is actually in, not the UTC date an hour behind it.
    func testJustAfterMidnightBucketsToTheNextLocalDayEvenThoughUTCIsStillThePreviousDay() {
        let instant = utcInstant(2026, 5, 14, 23, 30) // = 2026-05-15 00:30 WEST
        let day = ItineraryTimeZone.localDay(of: instant, in: lisbon)
        XCTAssertEqual(day, DayDate(year: 2026, month: 5, day: 15))
    }

    /// A late-evening Lisbon item (23:30 WEST) alongside the two genuine
    /// crossings above — confirms ordinary same-day bucketing still holds.
    func testLateEveningLisbonItemStaysOnItsOwnLisbonDate() {
        let instant = utcInstant(2026, 5, 14, 22, 30) // = 2026-05-14 23:30 WEST
        let day = ItineraryTimeZone.localDay(of: instant, in: lisbon)
        XCTAssertEqual(day, DayDate(year: 2026, month: 5, day: 14))
    }

    /// DST-boundary day: found dynamically via `nextDaylightSavingTimeTransition`
    /// rather than a hardcoded date, so this doesn't depend on knowing (or
    /// mis-guessing) exactly which Sunday the EU spring-forward falls on in
    /// 2026. The offset either side of the transition must genuinely
    /// differ, and the calendar day must not appear to skip or repeat.
    func testBucketingAcrossADSTBoundaryDay() {
        let yearStart = utcInstant(2026, 1, 1, 0, 0)
        guard let transition = lisbon.nextDaylightSavingTimeTransition(after: yearStart) else {
            return XCTFail("expected Europe/Lisbon to have a spring-forward transition in 2026")
        }

        let justBefore = transition.addingTimeInterval(-60)
        let justAfter = transition.addingTimeInterval(60)

        let dayBefore = ItineraryTimeZone.localDay(of: justBefore, in: lisbon)
        let dayAfter = ItineraryTimeZone.localDay(of: justAfter, in: lisbon)
        XCTAssertEqual(dayBefore, dayAfter, "a spring-forward transition must not appear to skip or repeat a calendar day")

        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = lisbon
        let transitionDayNoon = localCalendar.date(bySettingHour: 12, minute: 0, second: 0, of: justAfter)!
        let priorDayNoon = localCalendar.date(byAdding: .day, value: -1, to: transitionDayNoon)!

        let offsetOnTransitionDay = lisbon.secondsFromGMT(for: transitionDayNoon)
        let offsetDayBefore = lisbon.secondsFromGMT(for: priorDayNoon)
        XCTAssertNotEqual(
            offsetOnTransitionDay, offsetDayBefore,
            "the transition day's own offset must actually differ from the prior day's, not silently no-op"
        )
    }

    func testTimeStringFormatsWallClockInTheGivenZoneNotUTC() {
        let instant = utcInstant(2026, 5, 14, 12, 20) // 08:20 EDT
        XCTAssertEqual(ItineraryTimeZone.timeString(instant, in: newYork), "08:20")
    }

    func testCitySegmentReplacesUnderscoresWithSpaces() {
        XCTAssertEqual(ItineraryTimeZone.citySegment(of: "Europe/Lisbon"), "Lisbon")
        XCTAssertEqual(ItineraryTimeZone.citySegment(of: "America/New_York"), "New York")
    }

    func testZoneChangedIsFalseForTheTimelinesFirstItem() {
        let first = TestFixtures.makeItineraryItem(startsAt: .now, tz: "Europe/Lisbon")
        XCTAssertFalse(ItineraryTimeZone.zoneChanged(from: nil, to: first))
    }
}
