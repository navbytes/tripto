import XCTest
@testable import Tripto

/// `TripDateRangeFormat` (UX audit finding 5) — pure logic, no SwiftData/
/// view dependency (its own doc comment). The `calendar` param pins the
/// same-year/different-year *decision* deterministically (mirrors
/// `TripCardDateTextTests`), but the formatted strings still go through
/// `Date.formatted()`'s ambient locale, so assertions check for the year's
/// presence/absence and the separator rather than a hardcoded month-day
/// order that would vary by the machine's region format.
final class TripDateRangeFormatTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    func testSameCurrentYearOmitsTheYear() {
        let start = date(2027, 3, 14)
        let end = date(2027, 3, 20)
        let now = date(2027, 1, 1)
        let text = TripDateRangeFormat.text(start: start, end: end, now: now, calendar: calendar)
        XCTAssertFalse(text.contains("2027"), "same-current-year range shouldn't spell out the year: \(text)")
        XCTAssertTrue(text.contains("\u{2013}"), "visual variant should use an en-dash separator: \(text)")
    }

    func testSameNonCurrentYearAppendsTheYearOnce() {
        let start = date(2027, 3, 14)
        let end = date(2027, 3, 20)
        let now = date(2026, 1, 1)
        let text = TripDateRangeFormat.text(start: start, end: end, now: now, calendar: calendar)
        XCTAssertEqual(text.components(separatedBy: "2027").count - 1, 1, "the year should appear exactly once: \(text)")
        XCTAssertTrue(text.hasSuffix("2027"), "the single year should be appended at the end: \(text)")
    }

    func testYearSpanningRangeShowsYearOnBothEnds() {
        let start = date(2026, 12, 28)
        let end = date(2027, 1, 3)
        let now = date(2026, 1, 1)
        let text = TripDateRangeFormat.text(start: start, end: end, now: now, calendar: calendar)
        XCTAssertTrue(text.contains("2026"), "the start year should be shown: \(text)")
        XCTAssertTrue(text.contains("2027"), "the end year should be shown: \(text)")
        let separatorRange = text.range(of: "\u{2013}")
        XCTAssertNotNil(separatorRange)
        if let separatorRange {
            XCTAssertTrue(text[..<separatorRange.lowerBound].contains("2026"), "the start year should sit before the separator: \(text)")
            XCTAssertTrue(text[separatorRange.upperBound...].contains("2027"), "the end year should sit after the separator: \(text)")
        }
    }

    func testSpokenVariantUsesToInsteadOfEnDash() {
        let start = date(2027, 3, 14)
        let end = date(2027, 3, 20)
        let now = date(2027, 1, 1)
        let text = TripDateRangeFormat.spokenText(start: start, end: end, now: now, calendar: calendar)
        XCTAssertTrue(text.contains(" to "), "spoken variant should join with \"to\", not an en-dash: \(text)")
        XCTAssertFalse(text.contains("\u{2013}"), "spoken variant shouldn't carry the visual en-dash: \(text)")
    }

    func testSpokenVariantAlsoShowsYearWhenSpanning() {
        let start = date(2026, 12, 28)
        let end = date(2027, 1, 3)
        let now = date(2026, 1, 1)
        let text = TripDateRangeFormat.spokenText(start: start, end: end, now: now, calendar: calendar)
        XCTAssertTrue(text.contains(" to "), "spoken variant should join with \"to\": \(text)")
        XCTAssertTrue(text.contains("2026") && text.contains("2027"), "both years should be shown when spanning: \(text)")
    }
}
