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

    /// Trips tied on BOTH `startDate` AND `endDate` break ties by `id`,
    /// ascending (reviewer finding) — NOT by preserving whatever order the
    /// caller happened to hand them in. `sorted(by:)`'s own stability alone
    /// isn't enough: SwiftData `@Query`'s row order for ties isn't
    /// guaranteed stable across app launches, so two DIFFERENT input
    /// orderings of the exact same identical-range trips must still land on
    /// the exact same (id-sorted) output — proving the tie-break is a real
    /// deterministic key, not an accident of whatever order was handed in.
    /// All three share the same `end` too (P6.2 reviewer fix: `endDate` now
    /// sits ahead of `id` in the sort key) — isolating the id dimension the
    /// same way `testBeenWithEqualEndDatesBreaksTiesByIdAscending` already
    /// does for `been`, rather than mixing two different sort dimensions in
    /// one fixture.
    func testAheadWithEqualStartAndEndDatesBreaksTiesByIdAscending() {
        let same = day(2026, 7, 20)
        let sameEnd = day(2026, 7, 24)
        let first = trip(id: UUID(), start: same, end: sameEnd)
        let second = trip(id: UUID(), start: same, end: sameEnd)
        let third = trip(id: UUID(), start: same, end: sameEnd)
        let expectedIds = [first, second, third].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)

        let forward = HomeTripOrdering.ahead([first, second, third]) { _ in .upcoming }
        XCTAssertEqual(forward.map(\.id), expectedIds)
        let reversed = HomeTripOrdering.ahead([third, second, first]) { _ in .upcoming }
        XCTAssertEqual(reversed.map(\.id), expectedIds, "a different input order must still land on the same id-sorted output")
    }

    /// D4 (P6.2 reviewer, HIGH-adjacent): a trip sharing only the START
    /// date with a true duplicate pair (identical start AND end) must never
    /// sort BETWEEN them — `TripMergeDetection.survivorByShellId`'s whole
    /// adjacent-pair scan depends on this. Before the `endDate` sort key,
    /// this could fail purely on `id` string luck.
    func testATripSharingOnlyTheStartDateNeverSortsBetweenATrueDuplicatePair() throws {
        let start = day(2026, 7, 20)
        let pairEnd = day(2026, 7, 25)
        let first = trip(id: UUID(), start: start, end: pairEnd)
        let second = trip(id: UUID(), start: start, end: pairEnd)
        // Same start, but genuinely different (shorter) trip — no relation
        // to the pair above beyond a coincidental shared start date.
        let other = trip(id: UUID(), start: start, end: day(2026, 7, 21))

        let ahead = HomeTripOrdering.ahead([first, other, second]) { _ in .upcoming }
        let firstIndex = try XCTUnwrap(ahead.firstIndex { $0.id == first.id })
        let secondIndex = try XCTUnwrap(ahead.firstIndex { $0.id == second.id })
        XCTAssertEqual(abs(firstIndex - secondIndex), 1, "the true duplicate pair must be adjacent regardless of where `other` lands")
    }

    /// Same tie-break, `been` side (same reviewer finding, same reasoning).
    func testBeenWithEqualEndDatesBreaksTiesByIdAscending() {
        let same = day(2026, 3, 10)
        let first = trip(id: UUID(), start: day(2026, 3, 1), end: same)
        let second = trip(id: UUID(), start: day(2026, 3, 2), end: same)
        let expectedIds = [first, second].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)

        let forward = HomeTripOrdering.been([first, second]) { _ in .past }
        XCTAssertEqual(forward.map(\.id), expectedIds)
        let reversed = HomeTripOrdering.been([second, first]) { _ in .past }
        XCTAssertEqual(reversed.map(\.id), expectedIds)
    }

    /// Repeated calls against the identical (already-shuffled) input must
    /// return the identical order every time — guards against any hidden
    /// nondeterminism (e.g. a `Set`/`Dictionary` detour) creeping into
    /// `ahead` for same-day trips.
    func testAheadWithEqualStartDatesIsDeterministicAcrossRepeatedCalls() {
        let same = day(2026, 7, 20)
        let shuffled = (0..<6).map { _ in trip(id: UUID(), start: same, end: day(2026, 8, 1)) }.shuffled()
        let firstRun = HomeTripOrdering.ahead(shuffled) { _ in .upcoming }.map(\.id)
        let secondRun = HomeTripOrdering.ahead(shuffled) { _ in .upcoming }.map(\.id)
        XCTAssertEqual(firstRun, secondRun, "sorting the exact same input twice must produce the exact same order")
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

    /// docs/UX_REDESIGN_ROADMAP.md Phase 2's Naha case, one level up: the
    /// `ahead`/`been` split (not just `TripDateBucketing.bucket` alone,
    /// already covered in `DateBucketingTests`) must still keep a trip whose
    /// last night is 23:xx local, in a zone AHEAD of a device that's already
    /// turned its own calendar page, inside `ahead` — composed with the REAL
    /// `TripDateBucketing.liveTimeZone` + `.bucket` (not a stub), mirroring
    /// exactly how `HomeView.bucket(for:)` composes them (verified by
    /// reading; that composition itself is private there, untestable directly).
    func testAheadKeepsATripEndingLateTonightInAZoneAheadOfTheDevice() {
        var jst = Calendar(identifier: .gregorian)
        jst.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let nahaStay = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Naha stay",
            startsAt: instant(2026, 7, 20, 15, 0, tz: "Asia/Tokyo"),
            endsAt: instant(2026, 7, 26, 23, 0, tz: "Asia/Tokyo"),
            tz: "Asia/Tokyo"
        )
        let nahaTrip = trip(
            start: DayDate(year: 2026, month: 7, day: 20).asDate(calendar: jst),
            end: DayDate(year: 2026, month: 7, day: 26).asDate(calendar: jst)
        )
        // 2026-07-26 23:30 JST == 2026-07-27 02:30 in Auckland — the device
        // has already rolled its own calendar over; the trip's own zone
        // (derived from its items, not the device) hasn't.
        let now = instant(2026, 7, 26, 23, 30, tz: "Asia/Tokyo")
        let realBucket: (Trip) -> TripBucket = { candidate in
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TripDateBucketing.liveTimeZone(
                items: [nahaStay], deviceTimeZone: TimeZone(identifier: "Pacific/Auckland")!
            )
            return TripDateBucketing.bucket(startDate: candidate.startDate, endDate: candidate.endDate, today: now, calendar: calendar)
        }
        XCTAssertTrue(
            HomeTripOrdering.ahead([nahaTrip], bucket: realBucket).contains { $0.id == nahaTrip.id },
            "a trip on its last JST night must stay in `ahead` even once a device further east has rolled over"
        )
        XCTAssertTrue(HomeTripOrdering.been([nahaTrip], bucket: realBucket).isEmpty)

        // Sanity (same discipline as DateBucketingTests' own Naha cases):
        // judged against the DEVICE's own (Auckland) zone instead of the
        // trip's live zone, this exact same trip/instant really would
        // already read as past — proves the test isn't accidentally trivial.
        var auckland = Calendar(identifier: .gregorian)
        auckland.timeZone = TimeZone(identifier: "Pacific/Auckland")!
        XCTAssertEqual(
            TripDateBucketing.bucket(startDate: nahaTrip.startDate, endDate: nahaTrip.endDate, today: now, calendar: auckland),
            .past,
            "sanity: judged against the device's own zone this same trip/instant would already read as past"
        )
    }

    // MARK: - HomeTripDayLabels.bucket (reviewer HIGH: tz-west bucketing)

    /// The exact regression the reviewer named: device in Tokyo (east),
    /// trip's own items all in Honolulu (west) — `calendar.startOfDay(for:)`
    /// reinterpreting the trip's already-device-anchored `startDate`/
    /// `endDate` through the LIVE (Honolulu) zone would shift both a full
    /// day earlier, wrongly archiving a trip that's still live. Composed
    /// with the real `TripDateBucketing.liveTimeZone` (not a stub), mirroring
    /// exactly how `HomeView`'s `tripList` derives it.
    func testBucketKeepsATripLiveWhenDeviceIsEastOfTheTripsOwnZone() {
        let honolulu = "Pacific/Honolulu"
        var honoluluCal = Calendar(identifier: .gregorian)
        honoluluCal.timeZone = TimeZone(identifier: honolulu)!
        // A 5-night Honolulu stay — device-anchored start/end dates built
        // the same way `TripFormView.save()` builds them: whatever calendar
        // day the CREATING device's `Calendar.current` said, here simulated
        // as Tokyo (a device far east of Honolulu).
        var tokyoCal = Calendar(identifier: .gregorian)
        tokyoCal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let honoluluTrip = trip(
            start: DayDate(year: 2026, month: 7, day: 20).asDate(calendar: tokyoCal),
            end: DayDate(year: 2026, month: 7, day: 25).asDate(calendar: tokyoCal)
        )
        let stay = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Waikiki stay",
            startsAt: instant(2026, 7, 20, 15, 0, tz: honolulu),
            endsAt: instant(2026, 7, 25, 11, 0, tz: honolulu),
            tz: honolulu
        )
        let liveTimeZone = TripDateBucketing.liveTimeZone(items: [stay])
        XCTAssertEqual(liveTimeZone.identifier, honolulu, "sanity: the trip's own effective zone is Honolulu")

        // "Now" is 2026-07-22 09:00 in Tokyo — squarely inside the trip's
        // 5 nights, no matter which zone judges it.
        let now = instant(2026, 7, 22, 9, 0, tz: "Asia/Tokyo")
        let bucket = HomeTripDayLabels.bucket(trip: honoluluTrip, liveTimeZone: liveTimeZone, now: now, deviceCalendar: tokyoCal)
        XCTAssertEqual(bucket, .inProgress, "a trip mid-stay in a zone WEST of the device must still read as live")
    }

    /// The boundary case: the trip's LAST night, still live in its own
    /// (western) zone even though the device's own (eastern) zone would
    /// already call it over — the mirror of `DateBucketingTests`' own Naha
    /// case, but for the ahead/been split specifically.
    func testBucketDoesNotArchiveATripOnItsLastNightInAWesternZone() {
        let honolulu = "Pacific/Honolulu"
        var tokyoCal = Calendar(identifier: .gregorian)
        tokyoCal.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let honoluluTrip = trip(
            start: DayDate(year: 2026, month: 7, day: 20).asDate(calendar: tokyoCal),
            end: DayDate(year: 2026, month: 7, day: 25).asDate(calendar: tokyoCal)
        )
        let stay = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Waikiki stay",
            startsAt: instant(2026, 7, 20, 15, 0, tz: honolulu),
            endsAt: instant(2026, 7, 25, 11, 0, tz: honolulu),
            tz: honolulu
        )
        let liveTimeZone = TripDateBucketing.liveTimeZone(items: [stay])

        // 2026-07-25 20:00 Honolulu == 2026-07-26 15:00 Tokyo — the trip's
        // own last calendar day (the 25th, Honolulu) is still current, but a
        // device reading its OWN (Tokyo) calendar has already turned to the
        // 26th, past the trip's device-anchored `endDate` (the 25th).
        let now = instant(2026, 7, 25, 20, 0, tz: honolulu)
        let bucket = HomeTripDayLabels.bucket(trip: honoluluTrip, liveTimeZone: liveTimeZone, now: now, deviceCalendar: tokyoCal)
        XCTAssertEqual(bucket, .inProgress, "the trip's own last night in Honolulu must not be archived a day early")
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

    /// The boundary `pick`'s own filter (`startsAt >= now`) draws: an item
    /// starting at the EXACT current instant must still be picked, and one
    /// that started an instant before must not.
    func testPickIncludesAnItemStartingExactlyNowButExcludesOneInstantBefore() {
        let now = instant(2026, 7, 20, 12, 0, tz: "UTC")
        let rightNow = TestFixtures.makeItineraryItem(title: "Right now", startsAt: now)
        let justMissed = TestFixtures.makeItineraryItem(title: "Just missed it", startsAt: now.addingTimeInterval(-1))
        XCTAssertEqual(
            HomeFirstUp.pick(from: [justMissed, rightNow], now: now)?.id, rightNow.id,
            "`startsAt >= now` must include the exact boundary instant"
        )
    }

    /// No "too soon" exclusion exists (or should exist) in `pick` — an item
    /// under an hour away must still win as the earliest confirmed upcoming
    /// item, same as one further out.
    func testPickIncludesAnItemStartingInUnderAnHour() {
        let now = instant(2026, 7, 20, 12, 0, tz: "UTC")
        let in45Minutes = TestFixtures.makeItineraryItem(title: "Soon", startsAt: now.addingTimeInterval(45 * 60))
        let in3Hours = TestFixtures.makeItineraryItem(title: "Later", startsAt: now.addingTimeInterval(3 * 60 * 60))
        let picked = HomeFirstUp.pick(from: [in3Hours, in45Minutes], now: now)
        XCTAssertEqual(picked?.id, in45Minutes.id, "an item starting under an hour away must still win as the earliest upcoming")
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
        let tripStart = DayDate(year: 2026, month: 7, day: 22)
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
        let result = HomeTodayPlan.items(in: [tomorrow, today2, yesterday, today1], tripStart: tripStart, liveTimeZone: tz, now: now)
        XCTAssertEqual(result.map { $0.item.id }, [today1.id, today2.id])
    }

    func testItemsExcludesSuggestedItems() {
        let tz = TimeZone(identifier: "UTC")!
        let now = instant(2026, 7, 24, 8, 0, tz: "UTC")
        let tripStart = DayDate(year: 2026, month: 7, day: 22)
        let confirmed = TestFixtures.makeItineraryItem(
            title: "Real plan", startsAt: instant(2026, 7, 24, 9, 0, tz: "UTC"), status: .confirmed
        )
        let suggested = TestFixtures.makeItineraryItem(
            title: "Unreviewed", startsAt: instant(2026, 7, 24, 10, 0, tz: "UTC"), status: .suggested
        )
        let result = HomeTodayPlan.items(in: [confirmed, suggested], tripStart: tripStart, liveTimeZone: tz, now: now)
        XCTAssertEqual(result.map { $0.item.id }, [confirmed.id])
    }

    /// Reviewer MED finding: an ONGOING multi-night stay (check-in
    /// yesterday, check-out in 2 more nights) never itself `startsAt`
    /// today, but the itinerary tab's own `ItineraryDayBucketing.sections`
    /// still carries a `.staying` row for it on every night in between —
    /// `HomeTodayPlan.items` must count that row too, or Home's "+K more
    /// today" would under-count relative to what the itinerary shows.
    func testItemsIncludesAnOngoingStayThatCheckedInEarlier() {
        let tz = TimeZone(identifier: "UTC")!
        let now = instant(2026, 7, 24, 8, 0, tz: "UTC")
        let tripStart = DayDate(year: 2026, month: 7, day: 20)
        let stay = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Beach Hotel",
            startsAt: instant(2026, 7, 22, 15, 0, tz: "UTC"), endsAt: instant(2026, 7, 26, 11, 0, tz: "UTC"), tz: "UTC"
        )
        let result = HomeTodayPlan.items(in: [stay], tripStart: tripStart, liveTimeZone: tz, now: now)
        XCTAssertEqual(result.count, 1)
        guard case .staying(let item, _, _) = result.first else {
            return XCTFail("expected a `.staying` row for an ongoing stay, got \(String(describing: result.first))")
        }
        XCTAssertEqual(item.id, stay.id)
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
        let todayRows = HomeTodayPlan.items(in: items, tripStart: DayDate(year: 2026, month: 7, day: 22), liveTimeZone: tz, now: now)
        let panel = HomeTodayPanel.make(trip: fiveDayTrip, todayRows: todayRows, now: now, liveTimeZone: tz, deviceCalendar: utc)
        XCTAssertEqual(panel.rows.count, 2)
        XCTAssertEqual(panel.rows.map(\.title), ["Plan 0", "Plan 1"])
        XCTAssertEqual(panel.moreCount, 2)
    }

    /// The exact boundary `TodayPanelView`'s own `if panel.moreCount > 0`
    /// gate (HomeRegisterViews.swift) depends on: with exactly 2 items
    /// today, both render as rows and `moreCount` must be precisely `0`
    /// (not omitted, not negative) — the pure function's actual contract, so
    /// the view's gate has something correct to check against and never
    /// renders a phantom "+0 more today".
    func testTodayPanelMoreCountIsZeroNotOmittedWhenTodayHasExactlyTwoItems() {
        let tz = TimeZone(identifier: "Asia/Tokyo")!
        let now = instant(2026, 7, 24, 8, 0, tz: "Asia/Tokyo")
        let fiveDayTrip = trip(start: day(2026, 7, 22), end: day(2026, 7, 26))
        let items = (0..<2).map { offset in
            TestFixtures.makeItineraryItem(
                title: "Plan \(offset)", startsAt: instant(2026, 7, 24, 9 + offset, 0, tz: "Asia/Tokyo"), tz: "Asia/Tokyo"
            )
        }
        let todayRows = HomeTodayPlan.items(in: items, tripStart: DayDate(year: 2026, month: 7, day: 22), liveTimeZone: tz, now: now)
        let panel = HomeTodayPanel.make(trip: fiveDayTrip, todayRows: todayRows, now: now, liveTimeZone: tz, deviceCalendar: utc)
        XCTAssertEqual(panel.rows.count, 2, "both of today's items must render as rows")
        XCTAssertEqual(panel.moreCount, 0)
    }

    /// A staying row's own display text: no single clock time (the whole
    /// point of an all-day backdrop row), title carries the "Staying" cue.
    func testTodayPanelDisplaysAStayingRowWithNoTimeAndAStayingLabel() {
        let tz = TimeZone(identifier: "UTC")!
        let now = instant(2026, 7, 24, 8, 0, tz: "UTC")
        let fiveDayTrip = trip(start: day(2026, 7, 22), end: day(2026, 7, 26))
        let stay = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Beach Hotel",
            startsAt: instant(2026, 7, 22, 15, 0, tz: "UTC"), endsAt: instant(2026, 7, 26, 11, 0, tz: "UTC"), tz: "UTC"
        )
        let todayRows = HomeTodayPlan.items(in: [stay], tripStart: DayDate(year: 2026, month: 7, day: 22), liveTimeZone: tz, now: now)
        let panel = HomeTodayPanel.make(trip: fiveDayTrip, todayRows: todayRows, now: now, liveTimeZone: tz, deviceCalendar: utc)
        XCTAssertEqual(panel.rows.count, 1)
        XCTAssertEqual(panel.rows.first?.time, "")
        XCTAssertEqual(panel.rows.first?.title, "Staying \u{00B7} Beach Hotel")
    }

    /// "Day N of M" — day 1 is the trip's own start date; day 3 is two full
    /// days later.
    func testTodayPanelDayNumberCountsFromTripStart() {
        let tz = TimeZone(identifier: "UTC")!
        let now = instant(2026, 7, 24, 9, 0, tz: "UTC")
        let fiveDayTrip = trip(start: day(2026, 7, 22), end: day(2026, 7, 26))
        let panel = HomeTodayPanel.make(trip: fiveDayTrip, todayRows: [], now: now, liveTimeZone: tz, deviceCalendar: utc)
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
        let panel = HomeTodayPanel.make(trip: fiveDayTrip, todayRows: [], now: now, liveTimeZone: tz, deviceCalendar: utc)
        XCTAssertEqual(panel.dayNumber, 5)
    }

    /// Defensive/degenerate case: `Trip.startDate`/`endDate` are non-optional
    /// `Date`s (confirmed by reading `Trip.swift` — there's no "nil dates"
    /// case to construct), but nothing stops a corrupted import or manual
    /// edit from producing `startDate > endDate`. Un-clamped, `durationInDays`
    /// goes negative — this pins that `make`'s own `max(totalDays, 1)` /
    /// `min(max(dayNumber))` clamps hold even at this extreme, not just the
    /// "one day past the end" case `ClampsToTotalDays` above already covers.
    /// Matters beyond cosmetics: `DayProgressBar`'s `ForEach(1...max(
    /// totalDays, 1))` (HomeRegisterViews.swift) would crash on a
    /// zero/negative range without this clamp.
    func testTodayPanelClampsSafelyForATripWithReversedDates() {
        let tz = TimeZone(identifier: "UTC")!
        let now = instant(2026, 7, 24, 9, 0, tz: "UTC")
        let reversedTrip = trip(start: day(2026, 7, 26), end: day(2026, 7, 22))
        let panel = HomeTodayPanel.make(trip: reversedTrip, todayRows: [], now: now, liveTimeZone: tz, deviceCalendar: utc)
        XCTAssertEqual(panel.totalDays, 1, "a reversed date range must clamp to at least 1 day, never negative/zero")
        XCTAssertTrue(
            (1...panel.totalDays).contains(panel.dayNumber),
            "day number must stay inside 1...totalDays even for a degenerate trip"
        )
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

    /// Reviewer nit: a corrupted/reversed date range (`endDate < startDate`)
    /// must clamp to "1 day," never print a negative count.
    func testSubtitleTextClampsToOneDayForReversedDates() {
        let start = day(2026, 2, 10)
        let reversedTrip = trip(start: start, end: day(2026, 2, 5))
        let text = HomeBeenSummary.subtitleText(trip: reversedTrip, itemCount: 2, calendar: utc)
        let expectedMonth = start.formatted(.dateTime.month(.abbreviated))
        XCTAssertEqual(text, "\(expectedMonth) \u{00B7} 1 day \u{00B7} 2 items")
    }
}
