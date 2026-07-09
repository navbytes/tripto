import XCTest
@testable import Tripto

/// `TimelineBuilder.build`'s day-title/`isToday` logic (findings F1 + F8) —
/// `ItineraryDayBucketing.Section`s with no rows are enough to exercise
/// this since the title/`isToday` branch never touches `section.rows`.
final class TimelineBuilderTitleTests: XCTestCase {
    private func day(_ year: Int, _ month: Int, _ day: Int) -> DayDate { DayDate(year: year, month: month, day: day) }

    private func section(day: DayDate, dayNumber: Int) -> ItineraryDayBucketing.Section {
        ItineraryDayBucketing.Section(day: day, dayNumber: dayNumber, rows: [])
    }

    /// A dayNumber < 1 means the day sits before the trip's own start date
    /// (e.g. a stray pre-trip item) — it must read as "Before the trip",
    /// never a nonsensical "Day 0" or "Day -1".
    func testDayNumberZeroOrLessReadsAsBeforeTheTrip() {
        let sections = [section(day: day(2026, 5, 13), dayNumber: 0), section(day: day(2026, 5, 12), dayNumber: -1)]
        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:], tripDayCount: 6
        )
        XCTAssertTrue(models[0].title.hasPrefix("Before the trip \u{00B7} "), models[0].title)
        XCTAssertTrue(models[1].title.hasPrefix("Before the trip \u{00B7} "), models[1].title)
    }

    /// A dayNumber past `tripDayCount` (e.g. a stray post-checkout item)
    /// reads as "After the trip" rather than continuing the "Day N" count
    /// past the trip's actual length.
    func testDayNumberBeyondTripDayCountReadsAsAfterTheTrip() {
        let sections = [section(day: day(2026, 5, 21), dayNumber: 8)]
        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:], tripDayCount: 6
        )
        XCTAssertTrue(models[0].title.hasPrefix("After the trip \u{00B7} "), models[0].title)
    }

    /// Every dayNumber in `1...tripDayCount` keeps the existing "Day N"
    /// title — the two new outside-range cases above must not swallow it.
    func testDayNumberInsideTheTripRangeKeepsTheDayNTitle() {
        let sections = [section(day: day(2026, 5, 16), dayNumber: 3)]
        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:], tripDayCount: 6
        )
        XCTAssertTrue(models[0].title.hasPrefix("Day 3 \u{00B7} "), models[0].title)
    }

    /// `nil` `tripDayCount` (the old call-site shape) never applies the
    /// "After the trip" branch — existing behavior for callers that don't
    /// pass it stays exactly "Day N".
    func testNilTripDayCountNeverProducesAfterTheTripTitle() {
        let sections = [section(day: day(2026, 5, 30), dayNumber: 50)]
        let models = TimelineBuilder.build(sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:])
        XCTAssertTrue(models[0].title.hasPrefix("Day 50 \u{00B7} "), models[0].title)
    }

    /// `isToday` is true only for the section whose day exactly matches the
    /// `today` passed in, never for its neighbors.
    func testIsTodayMatchesOnlyTheGivenDay() {
        let sections = [
            section(day: day(2026, 5, 15), dayNumber: 2),
            section(day: day(2026, 5, 16), dayNumber: 3),
        ]
        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:], today: day(2026, 5, 16)
        )
        XCTAssertFalse(models[0].isToday)
        XCTAssertTrue(models[1].isToday)
    }

    /// `today: nil` (the old call-site shape) never marks any day as today.
    func testNilTodayNeverMarksADayAsToday() {
        let sections = [section(day: day(2026, 5, 15), dayNumber: 2)]
        let models = TimelineBuilder.build(sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:])
        XCTAssertFalse(models[0].isToday)
    }
}
