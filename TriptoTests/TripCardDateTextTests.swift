import XCTest
@testable import Tripto

/// `TripCard.startDateText` (UX audit finding 3): a same-year date omits the
/// year ("May 14"); a different year — prior (multi-year Past-tab history)
/// or next (a trip booked for next January) — gets the year appended so it
/// isn't ambiguous. The `calendar` param (fixed UTC, mirroring
/// `DateBucketingTests`) pins the same-year/different-year *decision*
/// deterministically; the formatted *string* itself still goes through
/// `Date.formatted()`'s ambient locale (the helper takes no locale param,
/// same as the view code it was extracted from), so assertions check for
/// the year's presence/absence rather than a hardcoded month-day order that
/// would vary by the machine's region format.
final class TripCardDateTextTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DayDate(year: year, month: month, day: day).asDate(calendar: utc)
    }

    func testSameYearDateOmitsYear() {
        let text = TripCard.startDateText(
            for: day(2026, 5, 14), asOf: day(2026, 7, 8), calendar: utc
        )
        XCTAssertFalse(text.contains("2026"), "same-year date shouldn't spell out the year: \(text)")
    }

    func testPriorYearDateIncludesYear() {
        let text = TripCard.startDateText(
            for: day(2024, 5, 14), asOf: day(2026, 7, 8), calendar: utc
        )
        XCTAssertTrue(text.contains("2024"), "prior-year date should include the year: \(text)")
    }

    func testNextYearDateIncludesYear() {
        let text = TripCard.startDateText(
            for: day(2027, 1, 3), asOf: day(2026, 7, 8), calendar: utc
        )
        XCTAssertTrue(text.contains("2027"), "next-year date should include the year: \(text)")
    }
}
