import XCTest
@testable import Tripto

/// Home's Upcoming/Past bucketing (BUILD_PLAN.md §4.1), with explicit
/// boundary-day cases — the exact place off-by-one bugs hide. Uses a fixed
/// UTC calendar throughout (never `Calendar.current`) so the test result
/// doesn't depend on the machine running it.
final class DateBucketingTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DayDate(year: year, month: month, day: day).asDate(calendar: utc)
    }

    /// Same recipe as `ItineraryDayBucketingTests`/`ItineraryTimeZoneTests`'
    /// own private `instant` helpers — an hour-precision instant built in a
    /// *named* zone (not UTC), for `liveTimeZone`'s own zone-derivation
    /// tests below.
    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, tz: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    func testFutureTripIsUpcoming() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 8, 1), endDate: day(2026, 8, 5), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .upcoming)
    }

    func testTripThatEndedBeforeTodayIsPast() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 5, 1), endDate: day(2026, 5, 5), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .past)
    }

    func testTripSpanningTodayIsInProgress() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 1), endDate: day(2026, 7, 10), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .inProgress)
    }

    func testBoundaryTripStartingTodayIsInProgressNotUpcoming() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 8), endDate: day(2026, 7, 12), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .inProgress)
    }

    func testBoundaryTripEndingTodayIsStillInProgressNotPast() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 1), endDate: day(2026, 7, 8), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .inProgress, "BUILD_PLAN.md §4.1: Past = end_date < today, strictly")
    }

    func testBoundaryTripThatEndedYesterdayIsPast() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 1), endDate: day(2026, 7, 7), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .past)
    }

    func testSingleDayTripToday() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 8), endDate: day(2026, 7, 8), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .inProgress)
    }

    func testDaysUntilStart() {
        let days = TripDateBucketing.daysUntilStart(
            startDate: day(2026, 7, 20), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(days, 12)
    }

    func testDaysUntilStartIsZeroOnStartDay() {
        let days = TripDateBucketing.daysUntilStart(
            startDate: day(2026, 7, 8), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(days, 0)
    }

    /// ACCEPTANCE.md "(c)": a 3-night stay (May 14 -> May 17) spans N+1 = 4
    /// calendar days.
    func testDurationInDaysIsInclusive() {
        let duration = TripDateBucketing.durationInDays(
            startDate: day(2026, 5, 14), endDate: day(2026, 5, 17), calendar: utc
        )
        XCTAssertEqual(duration, 4)
    }

    func testDurationInDaysForASingleDayTrip() {
        let duration = TripDateBucketing.durationInDays(
            startDate: day(2026, 5, 14), endDate: day(2026, 5, 14), calendar: utc
        )
        XCTAssertEqual(duration, 1)
    }

    // MARK: - liveTimeZone (docs/UX_REDESIGN_ROADMAP.md Phase 2, P2.4)

    func testLiveTimeZoneFallsBackToDeviceZoneWithNoItems() {
        let device = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(TripDateBucketing.liveTimeZone(items: [], deviceTimeZone: device), device)
    }

    /// The item that STARTS latest isn't necessarily the one that ENDS
    /// latest — `liveTimeZone` must sort by end instant, not start.
    func testLiveTimeZonePicksTheLatestEndingItemNotTheLatestStartingOne() {
        let earlyStartLateEnd = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Long stay",
            startsAt: instant(2026, 7, 20, 15, 0, tz: "Asia/Tokyo"),
            endsAt: instant(2026, 7, 26, 11, 0, tz: "Asia/Tokyo"),
            tz: "Asia/Tokyo"
        )
        let lateStartEarlyEnd = TestFixtures.makeItineraryItem(
            category: .activity, title: "Earlier errand",
            startsAt: instant(2026, 7, 22, 9, 0, tz: "America/New_York"),
            tz: "America/New_York"
        )
        let tz = TripDateBucketing.liveTimeZone(items: [lateStartEarlyEnd, earlyStartLateEnd])
        XCTAssertEqual(tz.identifier, "Asia/Tokyo")
    }

    /// A flight's own `tz` column is its DEPARTURE zone (`ItineraryTimeZone
    /// .swift`) — the zone that governs "what's today once this item is
    /// over" is `effectiveTz` (the arrival zone), not that departure zone.
    func testLiveTimeZoneUsesAFlightsEffectiveArrivalZoneNotItsDepartureZone() {
        var details = ItemDetails.empty
        details.arrivalTz = "Asia/Tokyo"
        let flight = TestFixtures.makeItineraryItem(
            category: .flight, title: "Homeward flight",
            startsAt: instant(2026, 7, 26, 9, 0, tz: "Asia/Bangkok"),
            endsAt: instant(2026, 7, 26, 17, 0, tz: "Asia/Bangkok"),
            tz: "Asia/Bangkok",
            details: details
        )
        let tz = TripDateBucketing.liveTimeZone(items: [flight])
        XCTAssertEqual(tz.identifier, "Asia/Tokyo")
    }

    /// The exact acceptance scenario (docs/UX_REDESIGN_ROADMAP.md Phase 2):
    /// a trip's last night in Naha (Asia/Tokyo) at 23:30 local is still
    /// "today" in the trip's own zone even though a device far enough east
    /// (Auckland, UTC+12) has already rolled its own calendar over to the
    /// next day.
    func testTripTzToday_deviceAheadOfTripTzStaysOnTheTripsLastDay() {
        let stay = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Naha stay",
            startsAt: instant(2026, 7, 20, 15, 0, tz: "Asia/Tokyo"),
            endsAt: instant(2026, 7, 26, 23, 0, tz: "Asia/Tokyo"),
            tz: "Asia/Tokyo"
        )
        let tripTz = TripDateBucketing.liveTimeZone(items: [stay])
        XCTAssertEqual(tripTz.identifier, "Asia/Tokyo")

        // 2026-07-26 23:30 JST == 2026-07-27 02:30 in Auckland.
        let now = instant(2026, 7, 26, 23, 30, tz: "Asia/Tokyo")
        var tripCalendar = Calendar(identifier: .gregorian)
        tripCalendar.timeZone = tripTz
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = TimeZone(identifier: "Pacific/Auckland")!

        XCTAssertEqual(
            DayDate.from(now, calendar: tripCalendar), DayDate(year: 2026, month: 7, day: 26),
            "the trip's own zone must still read this as the trip's last day"
        )
        XCTAssertEqual(
            DayDate.from(now, calendar: deviceCalendar), DayDate(year: 2026, month: 7, day: 27),
            "sanity: the device really has already rolled over while the trip's own zone hasn't"
        )
    }

    /// The mirror case: once the trip's own zone has turned the page, the
    /// trip must read as over even if a device lagging behind it (Honolulu,
    /// UTC-10) still shows the trip's last calendar day.
    func testTripTzToday_deviceBehindTripTzAlreadyReadsAsPast() {
        let stay = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Naha stay",
            startsAt: instant(2026, 7, 20, 15, 0, tz: "Asia/Tokyo"),
            endsAt: instant(2026, 7, 26, 23, 0, tz: "Asia/Tokyo"),
            tz: "Asia/Tokyo"
        )
        let tripTz = TripDateBucketing.liveTimeZone(items: [stay])

        // 2026-07-27 09:30 JST == 2026-07-26 14:30 in Honolulu.
        let now = instant(2026, 7, 27, 9, 30, tz: "Asia/Tokyo")
        var tripCalendar = Calendar(identifier: .gregorian)
        tripCalendar.timeZone = tripTz
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = TimeZone(identifier: "Pacific/Honolulu")!

        let tripToday = DayDate.from(now, calendar: tripCalendar)
        XCTAssertEqual(tripToday, DayDate(year: 2026, month: 7, day: 27))
        XCTAssertEqual(
            DayDate.from(now, calendar: deviceCalendar), DayDate(year: 2026, month: 7, day: 26),
            "sanity: the device is still a full day behind the trip's own zone"
        )
        XCTAssertLessThan(
            DayDate(year: 2026, month: 7, day: 26), tripToday,
            "the trip's last section day is strictly before trip-tz \u{2018}today\u{2019} — it must read as past"
        )
    }

    /// Baseline: device and trip zone agreeing must behave exactly as
    /// before this phase — no regression for the common case.
    func testTripTzToday_deviceEqualToTripTzMatchesBaseline() {
        let stay = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Naha stay",
            startsAt: instant(2026, 7, 20, 15, 0, tz: "Asia/Tokyo"),
            endsAt: instant(2026, 7, 26, 23, 0, tz: "Asia/Tokyo"),
            tz: "Asia/Tokyo"
        )
        let tripTz = TripDateBucketing.liveTimeZone(items: [stay])
        let now = instant(2026, 7, 26, 23, 30, tz: "Asia/Tokyo")
        var tripCalendar = Calendar(identifier: .gregorian)
        tripCalendar.timeZone = tripTz
        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!

        XCTAssertEqual(DayDate.from(now, calendar: tripCalendar), DayDate.from(now, calendar: deviceCalendar))
    }
}
