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

/// D4 ("now" presence, PLAN-signature-layer.md): `TimelineBuilder.build`'s
/// `.nowLine` insertion and `isPast` — hand-built `Section`s with real rows
/// (rather than going through `ItineraryDayBucketing`) so each placement is
/// pinned exactly, matching this file's existing isolate-the-builder style.
final class TimelineBuilderNowLineTests: XCTestCase {
    private func day(_ year: Int, _ month: Int, _ day: Int) -> DayDate { DayDate(year: year, month: month, day: day) }

    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, tz: String = "UTC") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    /// No section matches `today` — whether because it falls outside every
    /// section's day, or because `today` is `nil` entirely (the legacy
    /// call-site shape) — so no row anywhere gains a now-line.
    func testNowLineIsAbsentWhenTodayIsOutsideAnySection() {
        let upcoming = TestFixtures.makeItineraryItem(startsAt: instant(2026, 5, 15, 14, 0))
        let sections = [ItineraryDayBucketing.Section(day: day(2026, 5, 15), dayNumber: 1, rows: [.item(upcoming)])]

        let outsideRange = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:],
            now: instant(2026, 5, 20, 9, 0), today: day(2026, 5, 20)
        )
        XCTAssertFalse(outsideRange.flatMap(\.rows).contains { $0.id == "now-line" })

        let noToday = TimelineBuilder.build(sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:])
        XCTAssertFalse(noToday.flatMap(\.rows).contains { $0.id == "now-line" })
    }

    /// Today's section is real (a staying strip) but carries no
    /// instant-bearing row to anchor a line against — deliberately no
    /// now-line here rather than turning an otherwise-quiet backdrop day
    /// into a bare "Now" marker with nothing else.
    func testNowLineIsAbsentInTodaysSectionWhenItHasNoInstantBearingRows() {
        let stay = TestFixtures.makeItineraryItem(category: .hotel, startsAt: instant(2026, 5, 14, 15, 0))
        let sections = [
            ItineraryDayBucketing.Section(
                day: day(2026, 5, 15), dayNumber: 2, rows: [.staying(item: stay, night: 2, totalNights: 3)]
            ),
        ]
        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:],
            now: instant(2026, 5, 15, 9, 0), today: day(2026, 5, 15)
        )
        XCTAssertEqual(models[0].rows.map(\.id), ["staying-\(stay.id.uuidString)-2"])
    }

    /// Before-first: every instant-bearing row today is still ahead of
    /// `now`, so the line sits at the very top of the section.
    func testNowLineSitsBeforeTheFirstRowWhenEverythingTodayIsStillUpcoming() {
        let first = TestFixtures.makeItineraryItem(title: "Museum", startsAt: instant(2026, 5, 15, 9, 0))
        let second = TestFixtures.makeItineraryItem(category: .food, title: "Lunch", startsAt: instant(2026, 5, 15, 13, 0))
        let sections = [ItineraryDayBucketing.Section(day: day(2026, 5, 15), dayNumber: 2, rows: [.item(first), .item(second)])]

        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:],
            now: instant(2026, 5, 15, 8, 0), today: day(2026, 5, 15)
        )
        XCTAssertEqual(
            models[0].rows.map(\.id),
            ["now-line", "card-\(first.id.uuidString)", "card-\(second.id.uuidString)"]
        )
    }

    /// Mid: a past card, a past check-out, and an upcoming card — the line
    /// lands exactly between the past group and the upcoming row, and both
    /// instant-bearing row kinds (card `startsAt`, check-out `endsAt`)
    /// report `isPast` correctly.
    func testNowLineSitsBetweenPastAndUpcomingRowsToday() {
        let now = instant(2026, 5, 15, 12, 0)
        let pastCard = TestFixtures.makeItineraryItem(title: "Breakfast walk", startsAt: instant(2026, 5, 15, 8, 0))
        let pastCheckout = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Hotel", startsAt: instant(2026, 5, 13, 15, 0), endsAt: instant(2026, 5, 15, 10, 0)
        )
        let futureCard = TestFixtures.makeItineraryItem(category: .food, title: "Dinner", startsAt: instant(2026, 5, 15, 19, 0))
        let sections = [
            ItineraryDayBucketing.Section(
                day: day(2026, 5, 15), dayNumber: 2,
                rows: [.item(pastCard), .checkOut(item: pastCheckout), .item(futureCard)]
            ),
        ]

        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:], now: now, today: day(2026, 5, 15)
        )
        XCTAssertEqual(
            models[0].rows.map(\.id),
            [
                "card-\(pastCard.id.uuidString)", "checkout-\(pastCheckout.id.uuidString)",
                "now-line", "card-\(futureCard.id.uuidString)",
            ]
        )

        guard
            case .card(let pastModel) = models[0].rows[0],
            case .checkOut(let checkoutModel) = models[0].rows[1],
            case .card(let futureModel) = models[0].rows[3]
        else { return XCTFail("unexpected row shape") }
        XCTAssertTrue(pastModel.isPast)
        XCTAssertTrue(checkoutModel.isPast)
        XCTAssertFalse(futureModel.isPast)
    }

    /// After-last: every instant-bearing row today has already passed, so
    /// the line sits at the very bottom of the section.
    func testNowLineSitsAtTheEndWhenEverythingTodayHasAlreadyPassed() {
        let first = TestFixtures.makeItineraryItem(title: "Museum", startsAt: instant(2026, 5, 15, 9, 0))
        let second = TestFixtures.makeItineraryItem(category: .food, title: "Lunch", startsAt: instant(2026, 5, 15, 13, 0))
        let sections = [ItineraryDayBucketing.Section(day: day(2026, 5, 15), dayNumber: 2, rows: [.item(first), .item(second)])]

        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:],
            now: instant(2026, 5, 15, 21, 0), today: day(2026, 5, 15)
        )
        XCTAssertEqual(
            models[0].rows.map(\.id),
            ["card-\(first.id.uuidString)", "card-\(second.id.uuidString)", "now-line"]
        )
    }

    /// Midnight/day edge: a section dated the day *before* today reads as
    /// past outright — even for a row whose own raw instant is later than
    /// `now` (a cross-timezone corner the day-bucketing layer can produce,
    /// §7.4) — the section's own day wins rather than a second per-row
    /// now-derivation re-litigating it.
    func testCardInASectionBeforeTodayIsPastEvenIfItsOwnInstantIsStillAheadOfNow() {
        let now = instant(2026, 5, 15, 0, 0)
        let futureClockButPastDay = TestFixtures.makeItineraryItem(startsAt: instant(2026, 5, 15, 2, 0))
        let sections = [
            ItineraryDayBucketing.Section(day: day(2026, 5, 14), dayNumber: 1, rows: [.item(futureClockButPastDay)]),
        ]

        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:], now: now, today: day(2026, 5, 15)
        )
        guard case .card(let model) = models[0].rows.first else { return XCTFail("expected a card row") }
        XCTAssertTrue(model.isPast, "a section dated before today must read as past regardless of a row's own clock time")
    }

    /// Instant-equality edge: `now` exactly equal to a card's `startsAt`
    /// must not count as past yet — the line sits immediately before it.
    func testIsPastIsFalseWhenNowExactlyEqualsACardsStartsAt() {
        let now = instant(2026, 5, 15, 9, 0)
        let item = TestFixtures.makeItineraryItem(startsAt: now)
        let sections = [ItineraryDayBucketing.Section(day: day(2026, 5, 15), dayNumber: 2, rows: [.item(item)])]

        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:], now: now, today: day(2026, 5, 15)
        )
        XCTAssertEqual(models[0].rows.map(\.id), ["now-line", "card-\(item.id.uuidString)"])
        guard case .card(let model) = models[0].rows[1] else { return XCTFail("expected a card row") }
        XCTAssertFalse(model.isPast, "now == startsAt must not count as past yet")
    }
}
