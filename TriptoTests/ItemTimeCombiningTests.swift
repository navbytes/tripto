import XCTest
@testable import Tripto

/// The add-item form's date+time+zone math (this milestone's brief §4.3;
/// `ItemTimeCombining`'s own doc comment): combining a date-only and
/// time-only picker value into one instant in a specific IANA zone, and the
/// flight form's "+1 day" auto-detect default.
final class ItemTimeCombiningTests: XCTestCase {
    private func timeOfDay(_ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
    }

    // MARK: - suggestedArrivalDayOffset (the "+1 day" chip's default)

    /// This milestone's brief: "arrival wall < departure wall -> +1 day".
    func testArrivalWallClockEarlierThanDepartureSuggestsNextDay() {
        let offset = ItemTimeCombining.suggestedArrivalDayOffset(
            departsTimeOfDay: timeOfDay(22, 0), arrivesTimeOfDay: timeOfDay(6, 30)
        )
        XCTAssertEqual(offset, 1)
    }

    func testArrivalWallClockLaterThanDepartureSuggestsSameDay() {
        // ACCEPTANCE.md "(a)"'s own flight: 08:20 departure, 20:15 arrival.
        let offset = ItemTimeCombining.suggestedArrivalDayOffset(
            departsTimeOfDay: timeOfDay(8, 20), arrivesTimeOfDay: timeOfDay(20, 15)
        )
        XCTAssertEqual(offset, 0)
    }

    func testIdenticalWallClockTimesSuggestSameDay() {
        let offset = ItemTimeCombining.suggestedArrivalDayOffset(
            departsTimeOfDay: timeOfDay(10, 0), arrivesTimeOfDay: timeOfDay(10, 0)
        )
        XCTAssertEqual(offset, 0)
    }

    // MARK: - combine (date + time-of-day -> instant in a target zone)

    /// The suggestion above is only ever a *default* — `combine`'s
    /// `dayOffset` is a fully independent, explicit parameter (the "+1 day"
    /// chip's toggle), never re-derived from the wall clocks inside
    /// `combine` itself.
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
