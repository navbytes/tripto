import XCTest
@testable import Tripto

/// Day-grouping and multi-day-stay expansion (BUILD_PLAN.md §4.2;
/// ACCEPTANCE.md "(c)") — `ItineraryDayBucketing`'s own doc comment calls
/// these out as the exact cases worth pinning down with a test.
final class ItineraryDayBucketingTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> DayDate { DayDate(year: year, month: month, day: day) }

    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, tz: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    /// ACCEPTANCE.md "(c)"'s exact worked example: check-in 2026-05-14, 3
    /// nights, check-out 2026-05-17 -> 1 check-in card (day 1) + 2 staying
    /// strips (days 2-3) + 1 check-out chip (day 4), spanning N+1 = 4 days.
    func testThreeNightStayExpandsIntoCheckInTwoStayingStripsAndACheckOut() {
        let hotel = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Memmo Alfama",
            startsAt: instant(2026, 5, 14, 15, 0, tz: "Europe/Lisbon"),
            endsAt: instant(2026, 5, 17, 11, 0, tz: "Europe/Lisbon"),
            tz: "Europe/Lisbon"
        )
        let sections = ItineraryDayBucketing.sections(items: [hotel], tripStart: day(2026, 5, 14), calendar: utc)

        XCTAssertEqual(sections.count, 4, "an N-night stay must span N+1 calendar days")
        guard sections.count == 4 else { return }

        XCTAssertEqual(sections[0].day, day(2026, 5, 14))
        XCTAssertEqual(sections[0].rows.count, 1, "exactly one full detail card must exist for the stay")
        assertRow(sections[0].rows.first, isItem: true, message: "day 1 should carry the full check-in card")

        XCTAssertEqual(sections[1].day, day(2026, 5, 15))
        if case .staying(_, let night, let total)? = sections[1].rows.first {
            XCTAssertEqual(night, 2)
            XCTAssertEqual(total, 3)
        } else {
            XCTFail("day 2 should be a staying strip")
        }

        XCTAssertEqual(sections[2].day, day(2026, 5, 16))
        if case .staying(_, let night, let total)? = sections[2].rows.first {
            XCTAssertEqual(night, 3)
            XCTAssertEqual(total, 3)
        } else {
            XCTFail("day 3 should be a staying strip")
        }

        XCTAssertEqual(sections[3].day, day(2026, 5, 17))
        XCTAssertEqual(sections[3].rows.count, 1, "the check-out day must not also carry a duplicate full card")
        if case .checkOut? = sections[3].rows.first {
            // expected
        } else {
            XCTFail("day 4 should be a check-out row")
        }
    }

    /// Day numbering is 1-based off the *trip's* own start date, not
    /// whichever day happens to carry the earliest item (BUILD_PLAN.md §4.2).
    func testDayNumberingIsRelativeToTripStartNotTheEarliestItem() {
        let activity = TestFixtures.makeItineraryItem(
            category: .activity, startsAt: instant(2026, 5, 16, 10, 0, tz: "Europe/Lisbon"), tz: "Europe/Lisbon"
        )
        let sections = ItineraryDayBucketing.sections(items: [activity], tripStart: day(2026, 5, 14), calendar: utc)
        XCTAssertEqual(sections.first?.dayNumber, 3, "May 16 is Day 3 of a trip that starts May 14")
    }

    /// Same-day rows sort by instant, and day sections themselves come back
    /// in chronological order regardless of insertion order.
    func testItemsSortByInstantWithinADayAndSectionsSortByDay() {
        let breakfast = TestFixtures.makeItineraryItem(
            category: .food, title: "Breakfast", startsAt: instant(2026, 5, 15, 8, 0, tz: "Europe/Lisbon"), tz: "Europe/Lisbon"
        )
        let dinner = TestFixtures.makeItineraryItem(
            category: .food, title: "Dinner", startsAt: instant(2026, 5, 15, 20, 0, tz: "Europe/Lisbon"), tz: "Europe/Lisbon"
        )
        let museum = TestFixtures.makeItineraryItem(
            category: .activity, title: "Museum", startsAt: instant(2026, 5, 16, 10, 0, tz: "Europe/Lisbon"), tz: "Europe/Lisbon"
        )
        // Deliberately out of order and reversed day order on input.
        let sections = ItineraryDayBucketing.sections(
            items: [museum, dinner, breakfast], tripStart: day(2026, 5, 14), calendar: utc
        )

        XCTAssertEqual(sections.map(\.day), [day(2026, 5, 15), day(2026, 5, 16)], "sections must come back day-ascending")
        XCTAssertEqual(
            sections[0].rows.map(\.item.title), ["Breakfast", "Dinner"],
            "same-day rows must sort by instant, not insertion order"
        )
    }

    /// BUILD_PLAN.md §5.6: v1 only ever renders `'confirmed'` items —
    /// `'suggested'` ones are dropped before day-grouping even starts.
    func testSuggestedItemsAreDroppedFromTheTimeline() {
        let suggested = TestFixtures.makeItineraryItem(
            category: .activity, startsAt: instant(2026, 5, 15, 9, 0, tz: "Europe/Lisbon"), tz: "Europe/Lisbon",
            status: .suggested
        )
        let sections = ItineraryDayBucketing.sections(items: [suggested], tripStart: day(2026, 5, 14), calendar: utc)
        XCTAssertTrue(sections.isEmpty)
    }

    /// A single-day item (no multi-day expansion) produces exactly one row.
    func testASingleDayItemProducesExactlyOneRow() {
        let flight = TestFixtures.makeItineraryItem(
            category: .flight, startsAt: instant(2026, 5, 14, 8, 20, tz: "America/New_York"), tz: "America/New_York"
        )
        let sections = ItineraryDayBucketing.sections(items: [flight], tripStart: day(2026, 5, 14), calendar: utc)
        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.rows.count, 1)
    }

    private func assertRow(_ row: ItineraryDayBucketing.Row?, isItem: Bool, message: String) {
        guard let row else { return XCTFail(message) }
        if case .item = row {
            XCTAssertTrue(isItem, message)
        } else {
            XCTFail(message)
        }
    }

    // MARK: - F2: gap-day sections when `tripEnd` is supplied

    /// Items bracket a free day in the middle of the trip (Day 1 and Day 4)
    /// — with `tripEnd` set, every day in between still gets its own
    /// (empty-rowed) section instead of vanishing from the list.
    func testTripEndFillsGapDaysBetweenItems() {
        let arrival = TestFixtures.makeItineraryItem(
            category: .flight, startsAt: instant(2026, 5, 14, 8, 0, tz: "UTC")
        )
        let departure = TestFixtures.makeItineraryItem(
            category: .flight, startsAt: instant(2026, 5, 17, 20, 0, tz: "UTC")
        )
        let sections = ItineraryDayBucketing.sections(
            items: [arrival, departure], tripStart: day(2026, 5, 14), tripEnd: day(2026, 5, 17), calendar: utc
        )

        XCTAssertEqual(sections.map(\.day), [day(2026, 5, 14), day(2026, 5, 15), day(2026, 5, 16), day(2026, 5, 17)])
        XCTAssertEqual(sections[0].rows.count, 1, "day 1 keeps its real row")
        XCTAssertTrue(sections[1].rows.isEmpty, "day 2 is a free gap day")
        XCTAssertTrue(sections[2].rows.isEmpty, "day 3 is a free gap day")
        XCTAssertEqual(sections[3].rows.count, 1, "day 4 keeps its real row")
    }

    /// A trip with no items at all must still hit the view's empty state —
    /// `tripEnd` alone must never manufacture sections out of nothing.
    func testTripEndDoesNotFillGapsWhenThereAreNoItemsAtAll() {
        let sections = ItineraryDayBucketing.sections(
            items: [], tripStart: day(2026, 5, 14), tripEnd: day(2026, 5, 20), calendar: utc
        )
        XCTAssertTrue(sections.isEmpty)
    }

    /// An item the day before the trip officially starts keeps its own
    /// section (it's real data), and the in-range gap days around it are
    /// still filled independently.
    func testItemBeforeTripStartKeepsItsOwnSectionAlongsideFilledGapDays() {
        let earlyArrival = TestFixtures.makeItineraryItem(
            category: .flight, startsAt: instant(2026, 5, 13, 22, 0, tz: "UTC")
        )
        let activity = TestFixtures.makeItineraryItem(
            category: .activity, startsAt: instant(2026, 5, 16, 10, 0, tz: "UTC")
        )
        let sections = ItineraryDayBucketing.sections(
            items: [earlyArrival, activity], tripStart: day(2026, 5, 14), tripEnd: day(2026, 5, 16), calendar: utc
        )

        XCTAssertEqual(
            sections.map(\.day),
            [day(2026, 5, 13), day(2026, 5, 14), day(2026, 5, 15), day(2026, 5, 16)],
            "the pre-trip day is its own section, and days 14-16 are still fully filled"
        )
        XCTAssertEqual(sections[0].dayNumber, 0, "day before the trip is Day 0")
    }

    /// A corrupt/mistyped `tripEnd` far in the future must not walk the
    /// gap-fill loop indefinitely — beyond `maxGapFillDays` it's skipped
    /// entirely, leaving only the days rows actually touch.
    func testTripEndBeyondTheRangeCapSkipsGapFilling() {
        let item = TestFixtures.makeItineraryItem(
            category: .activity, startsAt: instant(2026, 5, 14, 10, 0, tz: "UTC")
        )
        let farTripEnd = day(2028, 5, 14) // ~730 days out, well past the 60-day cap
        let sections = ItineraryDayBucketing.sections(
            items: [item], tripStart: day(2026, 5, 14), tripEnd: farTripEnd, calendar: utc
        )
        XCTAssertEqual(sections.count, 1, "the cap should skip gap-filling rather than emit ~730 empty sections")
    }
}
