import XCTest
@testable import Tripto

/// docs/UX_REDESIGN_ROADMAP.md Phase 5 — the one-list comparator, register
/// selection, and the "next"/"now" registers' content builders
/// (`HomeRegisters.swift`). Uses a fixed UTC calendar throughout (never
/// `Calendar.current`), same discipline as `DateBucketingTests`, so results
/// don't depend on the machine running them.
final class HomeRegistersTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DayDate(year: year, month: month, day: day).asDate(calendar: utc)
    }

    /// Same recipe as `DateBucketingTests`' own private helper — an
    /// hour-precision instant built in a *named* zone (not UTC).
    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, tz: String) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    private func trip(id: UUID = UUID(), start: Date, end: Date) -> Trip {
        TestFixtures.makeTrip(id: id, startDate: start, endDate: end)
    }

    // MARK: - HomeTripOrdering (P5.1: one comparator, no special cases)

    func testAheadSortsSoonestStartFirst() {
        let far = trip(start: day(2026, 9, 1), end: day(2026, 9, 5))
        let near = trip(start: day(2026, 7, 20), end: day(2026, 7, 25))
        let ahead = HomeTripOrdering.ahead([far, near]) { _ in .upcoming }
        XCTAssertEqual(ahead.map(\.id), [near.id, far.id])
    }

    /// The roadmap's own claim: "a live trip falls out at position 0 on its
    /// own" — no `isInProgress` special case in the comparator, just plain
    /// `startDate` ascending, since a live trip's start is always in the
    /// past relative to any trip still ahead of it.
    func testLiveTripLandsFirstInAheadForFree() {
        let live = trip(start: day(2026, 7, 10), end: day(2026, 7, 15))
        let upcoming = trip(start: day(2026, 8, 1), end: day(2026, 8, 5))
        let buckets: [UUID: TripBucket] = [live.id: .inProgress, upcoming.id: .upcoming]
        let ahead = HomeTripOrdering.ahead([upcoming, live]) { buckets[$0.id] ?? .upcoming }
        XCTAssertEqual(ahead.map(\.id), [live.id, upcoming.id])
    }

    /// `been` sorts by `endDate`, not `startDate` — a trip that started
    /// later can still have ended first.
    func testBeenSortsMostRecentFirstByEndDate() {
        let startedLaterEndedEarlier = trip(start: day(2026, 6, 10), end: day(2026, 6, 12))
        let startedEarlierEndedLater = trip(start: day(2026, 5, 1), end: day(2026, 6, 20))
        let been = HomeTripOrdering.been([startedLaterEndedEarlier, startedEarlierEndedLater]) { _ in .past }
        XCTAssertEqual(been.map(\.id), [startedEarlierEndedLater.id, startedLaterEndedEarlier.id])
    }

    /// The exact boundary the "ahead"/"been" split must get right — composed
    /// with the real `TripDateBucketing.bucket` (not a stub), since this is
    /// what actually guards the app against a trip ending today vanishing
    /// into "been" a day early.
    func testBoundaryTripEndingTodayStaysAhead() {
        let today = day(2026, 7, 8)
        let endsToday = trip(start: day(2026, 7, 1), end: today)
        let realBucket: (Trip) -> TripBucket = { TripDateBucketing.bucket(startDate: $0.startDate, endDate: $0.endDate, today: today, calendar: self.utc) }
        XCTAssertTrue(HomeTripOrdering.ahead([endsToday], bucket: realBucket).contains { $0.id == endsToday.id })
        XCTAssertTrue(HomeTripOrdering.been([endsToday], bucket: realBucket).isEmpty)
    }

    func testOrderedIsAheadThenBeen() {
        let ahead1 = trip(start: day(2026, 8, 1), end: day(2026, 8, 5))
        let been1 = trip(start: day(2026, 1, 1), end: day(2026, 1, 5))
        let buckets: [UUID: TripBucket] = [ahead1.id: .upcoming, been1.id: .past]
        let ordered = HomeTripOrdering.ordered([been1, ahead1]) { buckets[$0.id] ?? .upcoming }
        XCTAssertEqual(ordered.map(\.id), [ahead1.id, been1.id])
    }

    // MARK: - HomeRegister.kind (register selection)

    func testFirstAheadTripThatIsLiveIsNow() {
        let live = trip(start: day(2026, 7, 5), end: day(2026, 7, 10))
        let kind = HomeRegister.kind(for: live, aheadFirstId: live.id, bucket: .inProgress)
        XCTAssertEqual(kind, .now)
    }

    func testFirstAheadTripThatIsUpcomingIsNext() {
        let upcoming = trip(start: day(2026, 8, 1), end: day(2026, 8, 5))
        let kind = HomeRegister.kind(for: upcoming, aheadFirstId: upcoming.id, bucket: .upcoming)
        XCTAssertEqual(kind, .next)
    }

    /// Only `ahead.first` earns `.next`/`.now` — the roadmap's "only the
    /// nearest trip earns this."
    func testNonFirstAheadTripIsPlain() {
        let second = trip(start: day(2026, 9, 1), end: day(2026, 9, 5))
        let firstId = UUID()
        let kind = HomeRegister.kind(for: second, aheadFirstId: firstId, bucket: .upcoming)
        XCTAssertEqual(kind, .plain)
    }

    func testPastTripIsBeenRegardlessOfAheadFirstId() {
        let past = trip(start: day(2026, 1, 1), end: day(2026, 1, 5))
        // Even in the (unreachable in practice) case `aheadFirstId` matched
        // this trip's own id, a past bucket must still win — `kind` checks
        // `bucket.isPastTab` first.
        let kind = HomeRegister.kind(for: past, aheadFirstId: past.id, bucket: .past)
        XCTAssertEqual(kind, .been)
    }

    // MARK: - HomeFirstUp (P5.2: "FIRST UP" strip)

    func testPickReturnsEarliestUpcomingConfirmedItem() {
        let now = instant(2026, 7, 20, 12, 0, tz: "UTC")
        let soonest = TestFixtures.makeItineraryItem(
            title: "Aquarium", startsAt: instant(2026, 7, 21, 9, 0, tz: "UTC")
        )
        let later = TestFixtures.makeItineraryItem(
            title: "Dinner", startsAt: instant(2026, 7, 22, 19, 0, tz: "UTC")
        )
        let past = TestFixtures.makeItineraryItem(
            title: "Old thing", startsAt: instant(2026, 7, 19, 9, 0, tz: "UTC")
        )
        let picked = HomeFirstUp.pick(from: [later, past, soonest], now: now)
        XCTAssertEqual(picked?.id, soonest.id)
    }

    func testPickReturnsNilWhenAllItemsAreAlreadyPast() {
        let now = instant(2026, 7, 20, 12, 0, tz: "UTC")
        let past1 = TestFixtures.makeItineraryItem(startsAt: instant(2026, 7, 19, 9, 0, tz: "UTC"))
        let past2 = TestFixtures.makeItineraryItem(startsAt: instant(2026, 7, 18, 9, 0, tz: "UTC"))
        XCTAssertNil(HomeFirstUp.pick(from: [past1, past2], now: now))
    }

    /// EI-2: an unreviewed email-import suggestion must never surface as
    /// "first up," even when it would otherwise be the earliest candidate.
    func testPickExcludesSuggestedItems() {
        let now = instant(2026, 7, 20, 12, 0, tz: "UTC")
        let suggestedEarlier = TestFixtures.makeItineraryItem(
            title: "Unreviewed", startsAt: instant(2026, 7, 20, 15, 0, tz: "UTC"), status: .suggested
        )
        let confirmedLater = TestFixtures.makeItineraryItem(
            title: "Confirmed", startsAt: instant(2026, 7, 21, 9, 0, tz: "UTC"), status: .confirmed
        )
        let picked = HomeFirstUp.pick(from: [suggestedEarlier, confirmedLater], now: now)
        XCTAssertEqual(picked?.id, confirmedLater.id)
    }

    func testTextIncludesRouteForFlight() {
        var details = ItemDetails.empty
        details.fromIATA = "HND"; details.toIATA = "OKA"
        let flight = TestFixtures.makeItineraryItem(
            category: .flight, title: "JL901", startsAt: instant(2026, 7, 22, 9, 40, tz: "Asia/Tokyo"),
            tz: "Asia/Tokyo", details: details
        )
        let model = HomeFirstUp(item: flight)
        XCTAssertEqual(model.text, "JL901 \u{00B7} HND \u{2192} OKA")
        XCTAssertEqual(model.time, "09:40")
        XCTAssertEqual(model.weekday, "Wed")
    }

    func testTextIsPlainTitleWhenNoRoute() {
        let activity = TestFixtures.makeItineraryItem(
            category: .activity, title: "Churaumi Aquarium", startsAt: instant(2026, 7, 22, 9, 30, tz: "Asia/Tokyo"),
            tz: "Asia/Tokyo"
        )
        let model = HomeFirstUp(item: activity)
        XCTAssertEqual(model.text, "Churaumi Aquarium")
    }

    // MARK: - HomeTodayPlan (P5.3: "now" register's inline mini-list)

    func testItemsFiltersToTodayInLiveTimeZone() {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let now = instant(2026, 7, 24, 8, 0, tz: "Asia/Tokyo")
        let today1 = TestFixtures.makeItineraryItem(
            title: "Breakfast", startsAt: instant(2026, 7, 24, 9, 0, tz: "Asia/Tokyo"), tz: "Asia/Tokyo"
        )
        let today2 = TestFixtures.makeItineraryItem(
            title: "Lunch", startsAt: instant(2026, 7, 24, 13, 0, tz: "Asia/Tokyo"), tz: "Asia/Tokyo"
        )
        let tomorrow = TestFixtures.makeItineraryItem(
            title: "Departure", startsAt: instant(2026, 7, 25, 9, 0, tz: "Asia/Tokyo"), tz: "Asia/Tokyo"
        )
        let yesterday = TestFixtures.makeItineraryItem(
            title: "Arrival", startsAt: instant(2026, 7, 23, 20, 0, tz: "Asia/Tokyo"), tz: "Asia/Tokyo"
        )
        let result = HomeTodayPlan.items(in: [tomorrow, today2, yesterday, today1], liveTimeZone: tz, now: now)
        XCTAssertEqual(result.map(\.id), [today1.id, today2.id])
    }

    func testItemsExcludesSuggestedItems() {
        let tz = TimeZone(identifier: "UTC")!
        let now = instant(2026, 7, 24, 8, 0, tz: "UTC")
        let confirmed = TestFixtures.makeItineraryItem(
            title: "Real plan", startsAt: instant(2026, 7, 24, 9, 0, tz: "UTC"), status: .confirmed
        )
        let suggested = TestFixtures.makeItineraryItem(
            title: "Unreviewed", startsAt: instant(2026, 7, 24, 10, 0, tz: "UTC"), status: .suggested
        )
        let result = HomeTodayPlan.items(in: [confirmed, suggested], liveTimeZone: tz, now: now)
        XCTAssertEqual(result.map(\.id), [confirmed.id])
    }

    /// The "+K more today" count: 4 items today, only the first 2 render as
    /// rows, the other 2 fold into `moreCount`.
    func testTodayPanelShowsFirstTwoRowsAndCountsTheRest() {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let now = instant(2026, 7, 24, 8, 0, tz: "Asia/Tokyo")
        let fiveDayTrip = trip(start: day(2026, 7, 22), end: day(2026, 7, 26))
        let items = (0..<4).map { offset in
            TestFixtures.makeItineraryItem(
                title: "Plan \(offset)", startsAt: instant(2026, 7, 24, 9 + offset, 0, tz: "Asia/Tokyo"), tz: "Asia/Tokyo"
            )
        }
        let todayItems = HomeTodayPlan.items(in: items, liveTimeZone: tz, now: now)
        let panel = HomeTodayPanel.make(trip: fiveDayTrip, todayItems: todayItems, now: now, liveTimeZone: tz, deviceCalendar: utc)
        XCTAssertEqual(panel.rows.count, 2)
        XCTAssertEqual(panel.rows.map(\.title), ["Plan 0", "Plan 1"])
        XCTAssertEqual(panel.moreCount, 2)
    }

    /// "Day N of M" — day 1 is the trip's own start date; day 3 is two full
    /// days later.
    func testTodayPanelDayNumberCountsFromTripStart() {
        let tz = TimeZone(identifier: "UTC")!
        let now = instant(2026, 7, 24, 9, 0, tz: "UTC")
        let fiveDayTrip = trip(start: day(2026, 7, 22), end: day(2026, 7, 26))
        let panel = HomeTodayPanel.make(trip: fiveDayTrip, todayItems: [], now: now, liveTimeZone: tz, deviceCalendar: utc)
        XCTAssertEqual(panel.dayNumber, 3)
        XCTAssertEqual(panel.totalDays, 5)
    }

    /// A trip judged live right at its very last moment must still report a
    /// day number inside `1...totalDays`, never one past the end.
    func testTodayPanelDayNumberClampsToTotalDays() {
        let tz = TimeZone(identifier: "UTC")!
        // A day after the trip's own end date — shouldn't happen given this
        // register only ever renders for a bucket the caller already judged
        // `.inProgress`, but the clamp is the defensive floor/ceiling either
        // way (`HomeTodayPanel.make`'s own doc comment).
        let now = instant(2026, 7, 30, 9, 0, tz: "UTC")
        let fiveDayTrip = trip(start: day(2026, 7, 22), end: day(2026, 7, 26))
        let panel = HomeTodayPanel.make(trip: fiveDayTrip, todayItems: [], now: now, liveTimeZone: tz, deviceCalendar: utc)
        XCTAssertEqual(panel.dayNumber, 5)
    }

    // MARK: - HomeBeenSummary (P5.4: "been" row subtitle)

    /// `subtitleText`'s month goes through `Date.formatted()`'s ambient
    /// locale, same as `TripCard.startDateText` (`TripCardDateTextTests`'
    /// own doc comment: no locale param, so a hardcoded month string would
    /// vary by the machine's region format) — computed here the identical
    /// way so the assertion can't diverge from production regardless of
    /// which locale actually runs it; only the day/item math (pure `Int`
    /// arithmetic, calendar-pinned via `utc`) is asserted as a literal.
    func testSubtitleTextFormat() {
        let start = day(2026, 2, 10)
        let fourDayTrip = trip(start: start, end: day(2026, 2, 13))
        let text = HomeBeenSummary.subtitleText(trip: fourDayTrip, itemCount: 6, calendar: utc)
        let expectedMonth = start.formatted(.dateTime.month(.abbreviated))
        XCTAssertEqual(text, "\(expectedMonth) \u{00B7} 4 days \u{00B7} 6 items")
    }

    func testSubtitleTextSingularizes() {
        let start = day(2026, 2, 10)
        let oneDayTrip = trip(start: start, end: start)
        let text = HomeBeenSummary.subtitleText(trip: oneDayTrip, itemCount: 1, calendar: utc)
        let expectedMonth = start.formatted(.dateTime.month(.abbreviated))
        XCTAssertEqual(text, "\(expectedMonth) \u{00B7} 1 day \u{00B7} 1 item")
    }
}
