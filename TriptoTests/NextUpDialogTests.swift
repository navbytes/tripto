import XCTest
@testable import Tripto

/// PLAN-signature-layer.md §D7 (W2-C): `NextUpDialog.build(snapshot:now:calendar:)`
/// is a pure `TripSnapshot -> String` function (no `AppIntent`/`IntentDialog`
/// machinery here) — every branch the Siri/Shortcuts answer can take is
/// exercised directly. Dates are built against a fixed UTC calendar (mirrors
/// `TripDateRangeFormatTests`' own convention) so the branch each test hits
/// (today/tomorrow/N-days, in-progress/upcoming/past) is deterministic
/// regardless of the machine's locale/zone. `ItineraryTimeZone.timeString`'s
/// "HH:mm" is itself locale-independent (own doc comment), but the zone
/// *abbreviation* isn't guaranteed identical across OS/ICU versions
/// (`TZShiftChipTests`' own precedent) — computed via `ItineraryTimeZone.
/// zoneLabel` here too rather than hardcoded, for the same reason.
final class NextUpDialogTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A UTC instant that reads as `hour:minute` when displayed in
    /// `America/New_York` — mirrors `DemoSeeder`'s own "construct via the
    /// item's own tz calendar" pattern so the fixture's wall-clock time
    /// matches what the assertion expects.
    private func nyInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var ny = Calendar(identifier: .gregorian)
        ny.timeZone = TimeZone(identifier: "America/New_York")!
        return ny.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    // MARK: - Empty

    func testNoSnapshotReadsAsNoUpcomingTrips() {
        XCTAssertEqual(
            NextUpDialog.build(snapshot: nil, now: date(2027, 3, 1), calendar: calendar),
            NextUpDialog.noTripsMessage
        )
    }

    func testSnapshotWithNoTripsReadsAsNoUpcomingTrips() {
        let now = date(2027, 3, 1)
        let snapshot = TripSnapshot(generatedAt: now, trips: [], focusTripItems: [])
        XCTAssertEqual(NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar), NextUpDialog.noTripsMessage)
    }

    /// `SyncStore.buildSnapshot` only ever writes upcoming/in-progress trips,
    /// but `now` here is evaluated at call time, not write time — a trip
    /// that's since ended (relative to `now`) must read as "nothing
    /// upcoming," not be announced as still in progress.
    func testTripThatHasSinceEndedReadsAsNoUpcomingTrips() {
        let trip = makeTrip(title: "Lisbon", start: date(2027, 3, 14), end: date(2027, 3, 20))
        let now = date(2027, 3, 25)
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [])
        XCTAssertEqual(NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar), NextUpDialog.noTripsMessage)
    }

    // MARK: - Next trip (upcoming, no near flight)

    func testUpcomingTripWithNoNearFlightReadsStartDateAndDaysUntil() {
        let now = date(2027, 3, 1)
        let trip = makeTrip(title: "Lisbon", start: date(2027, 3, 14), end: date(2027, 3, 20))
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [])

        let text = NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertTrue(text.hasPrefix("Your next trip is Lisbon \u{2014} starts"), text)
        XCTAssertTrue(text.contains("in 13 days"), text)
    }

    // MARK: - Travel day (in-progress trip, no near flight)

    func testInProgressTripReadsThroughPhrasing() {
        let now = date(2027, 3, 16)
        let trip = makeTrip(title: "Lisbon", start: date(2027, 3, 14), end: date(2027, 3, 20))
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [])

        let text = NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertTrue(text.hasPrefix("You\u{2019}re in Lisbon through"), text)
        XCTAssertFalse(text.contains("starts"), "in-progress phrasing must never fall into the upcoming-trip template: \(text)")
    }

    // MARK: - Next flight within 48h

    func testFlightDepartingTodayUsesTzAwarePhrasing() {
        let now = date(2027, 5, 14, 6, 0)
        let departure = nyInstant(2027, 5, 14, 8, 20)
        let nyZone = TimeZone(identifier: "America/New_York")!
        let expectedZoneLabel = ItineraryTimeZone.zoneLabel(for: nyZone, at: departure)
        let trip = makeTrip(title: "Lisbon", start: date(2027, 5, 14), end: date(2027, 5, 20))
        let flight = makeFlight(startsAt: departure, tz: nyZone.identifier, flightNo: "TP1234", toIATA: "LIS")
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [flight])

        let text = NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertEqual(text, "Flight TP1234 to LIS departs today at 08:20 \(expectedZoneLabel).")
    }

    func testFlightDepartingTomorrowUsesTomorrowWord() {
        let now = date(2027, 5, 14, 23, 0)
        let departure = nyInstant(2027, 5, 15, 8, 20)
        let nyZone = TimeZone(identifier: "America/New_York")!
        let expectedZoneLabel = ItineraryTimeZone.zoneLabel(for: nyZone, at: departure)
        let trip = makeTrip(title: "Lisbon", start: date(2027, 5, 14), end: date(2027, 5, 20))
        let flight = makeFlight(startsAt: departure, tz: nyZone.identifier, flightNo: "TP1234", toIATA: "LIS")
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [flight])

        let text = NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertEqual(text, "Flight TP1234 to LIS departs tomorrow at 08:20 \(expectedZoneLabel).")
    }

    /// Just inside the 48h window but two UTC calendar-day boundaries away
    /// (a flight in the last minute of the window, asked about in the first
    /// minute of "now"'s day) — must fall back to a weekday name, never
    /// "today"/"tomorrow".
    func testFlightTwoDaysOutUsesAWeekdayNameNotTodayOrTomorrow() {
        let now = date(2027, 5, 14, 0, 1)
        let departure = date(2027, 5, 16, 0, 0)
        let trip = makeTrip(title: "Lisbon", start: date(2027, 5, 14), end: date(2027, 5, 20))
        let flight = makeFlight(startsAt: departure, tz: "UTC", flightNo: "TP1234", toIATA: "LIS")
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [flight])

        let text = NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertFalse(text.contains("departs today"), text)
        XCTAssertFalse(text.contains("departs tomorrow"), text)
        XCTAssertTrue(text.hasPrefix("Flight TP1234 to LIS departs"), text)
    }

    func testFlightBeyondFortyEightHoursFallsBackToTripText() {
        let now = date(2027, 5, 10)
        let trip = makeTrip(title: "Lisbon", start: date(2027, 5, 14), end: date(2027, 5, 20))
        let flight = makeFlight(startsAt: nyInstant(2027, 5, 14, 8, 20), tz: "America/New_York", flightNo: "TP1234", toIATA: "LIS")
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [flight])

        let text = NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertTrue(text.hasPrefix("Your next trip is Lisbon"), "a flight >48h out must not preempt the trip-level answer: \(text)")
    }

    func testAlreadyDepartedFlightIsIgnored() {
        let now = date(2027, 5, 14, 14, 0)
        let trip = makeTrip(title: "Lisbon", start: date(2027, 5, 10), end: date(2027, 5, 20))
        let flight = makeFlight(startsAt: nyInstant(2027, 5, 14, 8, 20), tz: "America/New_York", flightNo: "TP1234", toIATA: "LIS")
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [flight])

        let text = NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertTrue(text.hasPrefix("You\u{2019}re in Lisbon through"), "an already-departed flight must never be read as 'next': \(text)")
    }

    func testNonFlightItemNeverProducesFlightText() {
        let now = date(2027, 5, 14, 6, 0)
        let trip = makeTrip(title: "Lisbon", start: date(2027, 5, 14), end: date(2027, 5, 20))
        let activity = makeFlight(
            startsAt: nyInstant(2027, 5, 14, 8, 20), tz: "America/New_York",
            flightNo: nil, toIATA: nil, category: .activity
        )
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [activity])

        let text = NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertFalse(text.hasPrefix("Flight"), text)
    }

    func testEarliestOfMultipleUpcomingFlightsWins() {
        let now = date(2027, 5, 14, 0, 0)
        let trip = makeTrip(title: "Lisbon", start: date(2027, 5, 14), end: date(2027, 5, 20))
        let later = makeFlight(startsAt: date(2027, 5, 15, 20, 0), tz: "UTC", flightNo: "LATE1", toIATA: "MAD")
        let earlier = makeFlight(startsAt: nyInstant(2027, 5, 14, 8, 20), tz: "America/New_York", flightNo: "TP1234", toIATA: "LIS")
        let snapshot = TripSnapshot(generatedAt: now, trips: [trip], focusTripItems: [later, earlier])

        let text = NextUpDialog.build(snapshot: snapshot, now: now, calendar: calendar)

        XCTAssertTrue(text.contains("TP1234"), text)
        XCTAssertFalse(text.contains("LATE1"), text)
    }

    // MARK: - Fixtures

    private func makeTrip(title: String, start: Date, end: Date) -> SnapshotTrip {
        SnapshotTrip(id: UUID(), title: title, coverGradient: "dusk", startDate: start, endDate: end, destination: "Lisbon, Portugal")
    }

    private func makeFlight(
        startsAt: Date, tz: String, flightNo: String?, toIATA: String?, category: SnapshotItem.Category = .flight
    ) -> SnapshotItem {
        SnapshotItem(
            id: UUID(), tripId: UUID(), title: "TAP TP1234", category: category,
            startsAt: startsAt, endsAt: nil, tz: tz,
            fromIATA: "JFK", toIATA: toIATA, flightNo: flightNo, locationName: "JFK"
        )
    }
}
