import XCTest
@testable import Tripto

/// The add-item form's date+time+zone math (this milestone's brief §4.3;
/// `ItemTimeCombining`'s own doc comment): combining a date-only and
/// time-only picker value into one instant in a specific IANA zone.
///
/// P7c (award audit #4): the wall-clock-only `suggestedArrivalDayOffset`
/// "+1 day" default this file used to also cover is gone — it was zone-blind
/// (a late-enough departure paired with an unrelated arrival default could
/// need +2 days to reach a valid arrival, which its 0/1 range couldn't
/// express) and is superseded by an explicit arrival *date* picker
/// (`AddItemSheet.flightInstants`/`FlightTimeValidationTests`), which makes
/// any day gap directly representable instead of guessed.
final class ItemTimeCombiningTests: XCTestCase {
    // MARK: - combine (date + time-of-day -> instant in a target zone)

    /// `dayOffset` is a fully independent, explicit parameter — never
    /// re-derived from the wall clocks inside `combine` itself.
    func testCombineAppliesAnExplicitDayOffsetRegardlessOfWallClockOrder() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2026, month: 5, day: 14))!
        let time = utc.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 23, minute: 0))!
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!

        let sameDay = ItemTimeCombining.combine(date: date, timeOfDay: time, dayOffset: 0, targetTz: tokyo, readingCalendar: utc)
        let nextDay = ItemTimeCombining.combine(date: date, timeOfDay: time, dayOffset: 1, targetTz: tokyo, readingCalendar: utc)
        XCTAssertEqual(nextDay.timeIntervalSince(sameDay), 86400, accuracy: 1)
    }

    /// Round-trips the exact ACCEPTANCE.md "(a)" departure: 2026-05-14
    /// 08:20 in `America/New_York` (EDT, UTC-4) must land on 12:20 UTC.
    func testCombineAnchorsTheResultInTheTargetTimeZoneNotTheReadingCalendar() {
        var readingCalendar = Calendar(identifier: .gregorian)
        readingCalendar.timeZone = TimeZone(identifier: "UTC")! // stand-in for whatever zone the picker UI displayed in
        let date = readingCalendar.date(from: DateComponents(year: 2026, month: 5, day: 14))!
        let time = readingCalendar.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 8, minute: 20))!

        let instant = ItemTimeCombining.combine(
            date: date, timeOfDay: time, targetTz: TimeZone(identifier: "America/New_York")!, readingCalendar: readingCalendar
        )

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let expected = utc.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 12, minute: 20))!
        XCTAssertEqual(instant, expected)
    }

    func testCombineWithZeroDayOffsetMatchesTheDateAndTimeAsGiven() {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let date = utc.date(from: DateComponents(year: 2026, month: 5, day: 14))!
        let time = utc.date(from: DateComponents(hour: 15, minute: 0))!

        let instant = ItemTimeCombining.combine(date: date, timeOfDay: time, targetTz: TimeZone(identifier: "UTC")!, readingCalendar: utc)
        let expected = utc.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 15, minute: 0))!
        XCTAssertEqual(instant, expected)
    }
}
