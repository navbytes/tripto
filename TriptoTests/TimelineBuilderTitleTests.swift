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
            section(day: day(2026, 5, 16), dayNumber: 3)
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
            )
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
            )
        ]

        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:], now: now, today: day(2026, 5, 15)
        )
        XCTAssertEqual(
            models[0].rows.map(\.id),
            [
                "card-\(pastCard.id.uuidString)", "checkout-\(pastCheckout.id.uuidString)",
                "now-line", "card-\(futureCard.id.uuidString)"
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
            ItineraryDayBucketing.Section(day: day(2026, 5, 14), dayNumber: 1, rows: [.item(futureClockButPastDay)])
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

/// docs/UX_REDESIGN_ROADMAP.md Phase 1: `TZShiftChipRow`'s visual restyle
/// must not change what `TimelineBuilder.build` itself emits — this pins
/// the existing row order/content plus the new `TZShiftModel.kind` tag that
/// lets `ItineraryTabView` skip a landing row now shown in its flight's own
/// `BoardingPassCard` footer instead of a second rail marker.
final class TimelineBuilderTZShiftKindTests: XCTestCase {
    private func day(_ year: Int, _ month: Int, _ day: Int) -> DayDate { DayDate(year: year, month: month, day: day) }

    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, tz: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    /// The exact HKG->BKK scenario the design mockup illustrates: a flight
    /// lands in a new zone, and the very next item (already booked in the
    /// arrival zone) triggers no *separate* zone-change chip — only the
    /// flight's own landing row, which must be tagged `.landing` so the
    /// view knows not to render a second marker for it. Row order/ids are
    /// unchanged from before this milestone.
    func testLandingRowIsTaggedAndOrderedRightAfterItsFlightCard() {
        var details = ItemDetails.empty
        details.arrivalTz = "Asia/Bangkok"
        let flight = TestFixtures.makeItineraryItem(
            category: .flight,
            startsAt: instant(2026, 7, 20, 12, 20, tz: "Asia/Hong_Kong"),
            endsAt: instant(2026, 7, 20, 14, 0, tz: "Asia/Bangkok"),
            tz: "Asia/Hong_Kong", details: details
        )
        let rentalCar = TestFixtures.makeItineraryItem(
            category: .transport, startsAt: instant(2026, 7, 20, 14, 45, tz: "Asia/Bangkok"), tz: "Asia/Bangkok"
        )
        let sections = [
            ItineraryDayBucketing.Section(day: day(2026, 7, 20), dayNumber: 1, rows: [.item(flight), .item(rentalCar)])
        ]

        let models = TimelineBuilder.build(sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:])

        XCTAssertEqual(
            models[0].rows.map(\.id),
            ["card-\(flight.id.uuidString)", "landing-\(flight.id.uuidString)", "card-\(rentalCar.id.uuidString)"]
        )
        guard case .tzShift(let landingModel) = models[0].rows[1] else { return XCTFail("expected a tzShift row") }
        XCTAssertEqual(landingModel.kind, .landing)
    }

    /// A genuine non-flight zone crossing is still tagged `.zoneChange` —
    /// the kind that keeps rendering as the rail's hairline marker.
    func testNonFlightZoneCrossingIsTaggedZoneChange() {
        let lisbonActivity = TestFixtures.makeItineraryItem(
            category: .activity, startsAt: instant(2026, 5, 21, 8, 0, tz: "Europe/Lisbon"), tz: "Europe/Lisbon"
        )
        let madridActivity = TestFixtures.makeItineraryItem(
            category: .activity, startsAt: instant(2026, 5, 21, 12, 0, tz: "Europe/Madrid"), tz: "Europe/Madrid"
        )
        let sections = [
            ItineraryDayBucketing.Section(
                day: day(2026, 5, 21), dayNumber: 1, rows: [.item(lisbonActivity), .item(madridActivity)]
            )
        ]

        let models = TimelineBuilder.build(sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:])

        XCTAssertEqual(
            models[0].rows.map(\.id),
            [
                "card-\(lisbonActivity.id.uuidString)", "shift-to-\(madridActivity.id.uuidString)",
                "card-\(madridActivity.id.uuidString)"
            ]
        )
        guard case .tzShift(let shiftModel) = models[0].rows[1] else { return XCTFail("expected a tzShift row") }
        XCTAssertEqual(shiftModel.kind, .zoneChange)
    }

    /// Round-trip regression (docs/UX_REDESIGN_ROADMAP.md Phase 1): a
    /// multi-flight, multi-tz itinerary — the mockup's own HKG<->BKK city
    /// pair, there and back — must keep exactly the marker kinds/order this
    /// milestone's single-flight tests above already pin: two landing rows,
    /// zero spurious zone-change rows in between, even though the return
    /// leg re-crosses back through Hong Kong's own zone (a bug in
    /// `effectiveTz`/`zoneChanged` could otherwise fire a redundant
    /// zone-change chip right before the return flight's own card). Also
    /// pins the "one surface" contract (DECISIONS.md 2026-07-15): each
    /// flight's `boardingPass.footerText` — the pass footer, the one
    /// surface a viewer actually sees since `ItineraryTabView`
    /// view-suppresses the `.landing` row — carries byte-identical text to
    /// its suppressed-but-still-emitted `.tzShift(kind: .landing)` sibling,
    /// so the two can never silently drift apart.
    func testRoundTripMultiFlightKeepsLandingKindsOrderAndMatchingFooterText() {
        var outboundDetails = ItemDetails.empty
        outboundDetails.arrivalTz = "Asia/Bangkok"
        let outbound = TestFixtures.makeItineraryItem(
            category: .flight,
            startsAt: instant(2026, 7, 20, 12, 20, tz: "Asia/Hong_Kong"),
            endsAt: instant(2026, 7, 20, 14, 0, tz: "Asia/Bangkok"),
            tz: "Asia/Hong_Kong", details: outboundDetails
        )
        var returnDetails = ItemDetails.empty
        returnDetails.arrivalTz = "Asia/Hong_Kong"
        let returnFlight = TestFixtures.makeItineraryItem(
            category: .flight,
            startsAt: instant(2026, 7, 27, 15, 30, tz: "Asia/Bangkok"),
            endsAt: instant(2026, 7, 27, 19, 10, tz: "Asia/Hong_Kong"),
            tz: "Asia/Bangkok", details: returnDetails
        )
        let sections = [
            ItineraryDayBucketing.Section(day: day(2026, 7, 20), dayNumber: 1, rows: [.item(outbound)]),
            ItineraryDayBucketing.Section(day: day(2026, 7, 27), dayNumber: 8, rows: [.item(returnFlight)])
        ]

        let models = TimelineBuilder.build(sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:])

        XCTAssertEqual(models[0].rows.map(\.id), ["card-\(outbound.id.uuidString)", "landing-\(outbound.id.uuidString)"])
        XCTAssertEqual(
            models[1].rows.map(\.id), ["card-\(returnFlight.id.uuidString)", "landing-\(returnFlight.id.uuidString)"]
        )

        guard
            case .card(let outboundCard) = models[0].rows[0], case .tzShift(let outboundLanding) = models[0].rows[1],
            case .card(let returnCard) = models[1].rows[0], case .tzShift(let returnLanding) = models[1].rows[1]
        else { return XCTFail("unexpected row shape") }

        XCTAssertEqual(outboundLanding.kind, .landing)
        XCTAssertEqual(returnLanding.kind, .landing)
        XCTAssertNotEqual(outboundLanding.text, returnLanding.text, "outbound and return legs must not share a landing note")
        XCTAssertEqual(outboundCard.boardingPass?.footerText, outboundLanding.text)
        XCTAssertEqual(returnCard.boardingPass?.footerText, returnLanding.text)
    }

    /// Milestone add-on (P1/P2 ux check, wired in Phase 3): the pass face
    /// gains the same parity indicators every other row already shows —
    /// `TimelineBuilder.cardModel` already computes `pendingRowIds
    /// .contains(item.id)` and `assigneesByItem[item.id]` for
    /// `TimelineCardModel` itself; this pins that a flight's
    /// `boardingPass` gets the identical values, not silently `false`/`[]`
    /// just because it renders as a pass instead of `legacyCard`.
    func testBoardingPassCarriesTheSamePendingAndAssigneeStateAsItsOwnCardModel() {
        var details = ItemDetails.empty
        details.fromIATA = "HKG"; details.toIATA = "BKK"
        let flight = TestFixtures.makeItineraryItem(
            category: .flight,
            startsAt: instant(2026, 7, 20, 12, 20, tz: "Asia/Hong_Kong"), tz: "Asia/Hong_Kong", details: details
        )
        let priya = AvatarStack.Person(id: UUID(), initial: "P", colorName: "moss", name: "Priya")
        let sections = [
            ItineraryDayBucketing.Section(day: day(2026, 7, 20), dayNumber: 1, rows: [.item(flight)])
        ]

        let models = TimelineBuilder.build(
            sections: sections, pendingRowIds: [flight.id], myUserId: nil, namesById: [:],
            assigneesByItem: [flight.id: [priya]]
        )

        guard case .card(let cardModel) = models[0].rows[0] else { return XCTFail("expected a card row") }
        XCTAssertTrue(cardModel.isPending)
        XCTAssertEqual(cardModel.assignees, [priya])
        XCTAssertEqual(cardModel.boardingPass?.isPending, cardModel.isPending)
        XCTAssertEqual(cardModel.boardingPass?.assignees, cardModel.assignees)
    }

    /// A flight with no known arrival zone at all has nothing to land into
    /// — no footer, no `.landing` row (`BoardingPassContentTests
    /// .testFooterTextIsAbsentWhenArrivalZoneMatchesDeparture` covers the
    /// same-zone case; this one has no `arrivalTz` at all). But the
    /// *incoming* crossing into its own departure zone is a separate,
    /// ordinary `.zoneChange` chip that fires for any item regardless of
    /// category — it must not be silently swallowed by the same
    /// `.landing`-suppression mechanism just because the row right after it
    /// happens to be a flight.
    func testIncomingZoneChangeBeforeAFlightWithNoArrivalTzIsNotLost() {
        let lisbonActivity = TestFixtures.makeItineraryItem(
            category: .activity, startsAt: instant(2026, 5, 20, 9, 0, tz: "Europe/Lisbon"), tz: "Europe/Lisbon"
        )
        let localFlight = TestFixtures.makeItineraryItem(
            category: .flight, startsAt: instant(2026, 5, 21, 10, 0, tz: "Europe/Madrid"), tz: "Europe/Madrid"
        )
        let sections = [
            ItineraryDayBucketing.Section(day: day(2026, 5, 20), dayNumber: 1, rows: [.item(lisbonActivity)]),
            ItineraryDayBucketing.Section(day: day(2026, 5, 21), dayNumber: 2, rows: [.item(localFlight)])
        ]

        let models = TimelineBuilder.build(sections: sections, pendingRowIds: [], myUserId: nil, namesById: [:])

        XCTAssertEqual(
            models[1].rows.map(\.id), ["shift-to-\(localFlight.id.uuidString)", "card-\(localFlight.id.uuidString)"]
        )
        guard case .tzShift(let shiftModel) = models[1].rows[0] else { return XCTFail("expected a tzShift row") }
        XCTAssertEqual(shiftModel.kind, .zoneChange)
    }
}
