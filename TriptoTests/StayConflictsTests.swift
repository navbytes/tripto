import XCTest
@testable import Tripto

/// Stay-overlap detection (docs/UX_REDESIGN_ROADMAP.md Phase 2, P2.1) — the
/// overlap matrix the roadmap calls out (full/partial/adjacent-nights/none/
/// nil-endsAt), plus the ordering/wording contracts `ItineraryTabView`'s
/// banner and per-card flag rely on.
final class StayConflictsTests: XCTestCase {
    /// Same recipe as `ItineraryDayBucketingTests`/`ItineraryTimeZoneTests`'
    /// own private `instant` helpers.
    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, tz: String = "Asia/Bangkok") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    private func hotel(_ title: String, checkIn: Date, checkOut: Date?, tz: String = "Asia/Bangkok") -> ItineraryItem {
        TestFixtures.makeItineraryItem(category: .hotel, title: title, startsAt: checkIn, endsAt: checkOut, tz: tz)
    }

    // MARK: - Overlap matrix

    func testFullOverlapSameDatesIsFlaggedAsFullOverlap() {
        let a = hotel("Pullman Bangkok", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 26, 11, 0))
        let b = hotel("M\u{f6}venpick Khao Yai", checkIn: instant(2026, 7, 20, 15, 0), checkOut: instant(2026, 7, 26, 12, 0))
        let conflicts = StayConflicts.conflicts(in: [a, b])
        XCTAssertEqual(conflicts.count, 1)
        guard let conflict = conflicts.first else { return }
        XCTAssertEqual(conflict.sharedNights, 6)
        XCTAssertTrue(conflict.isFullOverlap)
        XCTAssertEqual(conflict.firstId, a.id)
        XCTAssertEqual(conflict.secondId, b.id)
    }

    func testPartialOverlapIsFlaggedButNotFull() {
        // Six-night stay (nights 20-25).
        let a = hotel("Six-night stay", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 26, 11, 0))
        // Extension stay (nights 24-27).
        let b = hotel("Extension stay", checkIn: instant(2026, 7, 24, 14, 0), checkOut: instant(2026, 7, 28, 11, 0))
        let conflicts = StayConflicts.conflicts(in: [a, b])
        XCTAssertEqual(conflicts.count, 1)
        guard let conflict = conflicts.first else { return }
        XCTAssertEqual(conflict.sharedNights, 2, "shared nights are the 24th and 25th only")
        XCTAssertFalse(conflict.isFullOverlap)
    }

    /// A check-out and the next stay's check-in on the SAME calendar day
    /// must not conflict — the check-out morning isn't an occupied night.
    func testAdjacentNightsAtACommonCheckoutCheckinDayIsNotAConflict() {
        // First hotel (nights 20-22).
        let a = hotel("First hotel", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 23, 11, 0))
        // Second hotel (nights 23-25).
        let b = hotel("Second hotel", checkIn: instant(2026, 7, 23, 15, 0), checkOut: instant(2026, 7, 26, 11, 0))
        XCTAssertTrue(StayConflicts.conflicts(in: [a, b]).isEmpty)
    }

    /// Walk-in twin of the adjacency test above: same same-day
    /// checkout-then-check-in shape, but B has no `endsAt` at all. Reviewer
    /// D3 (fixed): the nil-endsAt fallback used to start its window at
    /// LOCAL MIDNIGHT of the check-in day — hours before A's real 11:00
    /// checkout — manufacturing a phantom "overlap" between a stay that had
    /// already checked out and a walk-in that hadn't checked in yet.
    func testWalkInCheckInAfterAnotherStaysSameDayCheckoutIsNotAConflict() {
        // First hotel (nights 20-22), checks out the morning of the 23rd.
        let a = hotel("First hotel", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 23, 11, 0))
        // Walk-in booking, checks in the afternoon of the 23rd — after checkout.
        let b = hotel("Walk-in booking", checkIn: instant(2026, 7, 23, 15, 0), checkOut: nil)
        XCTAssertTrue(StayConflicts.conflicts(in: [a, b]).isEmpty)
    }

    func testDisjointStaysAreNotAConflict() {
        let a = hotel("First hotel", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 23, 11, 0))
        let b = hotel("Second hotel", checkIn: instant(2026, 7, 25, 14, 0), checkOut: instant(2026, 7, 28, 11, 0))
        XCTAssertTrue(StayConflicts.conflicts(in: [a, b]).isEmpty)
    }

    /// A missing `endsAt` is treated as a single-night stay occupying only
    /// its own check-in night — it must overlap a stay that genuinely
    /// covers that night...
    func testNilEndsAtOverlappingAnotherStayIsFlaggedAsASingleNight() {
        // Walk-in booking, night of the 20th only.
        let a = hotel("Walk-in booking", checkIn: instant(2026, 7, 20, 20, 0), checkOut: nil)
        // Longer stay (nights 19-21).
        let b = hotel("Longer stay", checkIn: instant(2026, 7, 19, 14, 0), checkOut: instant(2026, 7, 22, 11, 0))
        let conflicts = StayConflicts.conflicts(in: [a, b])
        XCTAssertEqual(conflicts.count, 1)
        XCTAssertEqual(conflicts.first?.sharedNights, 1)
    }

    /// ...but must NOT bleed into the following night it was never booked for.
    func testNilEndsAtDoesNotConflictWithAStayStartingTheNextNight() {
        // Walk-in booking, night of the 20th only.
        let a = hotel("Walk-in booking", checkIn: instant(2026, 7, 20, 20, 0), checkOut: nil)
        // Later stay (nights 21-23).
        let b = hotel("Later stay", checkIn: instant(2026, 7, 21, 14, 0), checkOut: instant(2026, 7, 24, 11, 0))
        XCTAssertTrue(StayConflicts.conflicts(in: [a, b]).isEmpty)
    }

    /// Mirror ordering: a walk-in checking in EARLY in the day still claims
    /// its whole check-in night — `[startsAt, following midnight)` — so a
    /// real stay checking in LATER that same day genuinely lands inside the
    /// walk-in's still-open night and must still be flagged. This is the
    /// fix's other half: moving the fallback's START to the real check-in
    /// (instead of midnight) kills the phantom pre-check-in overlap above
    /// without also hiding a same-day collision that's actually real.
    func testWalkInCheckInEarlyInTheDayStillConflictsWithARealStayCheckingInLaterThatDay() {
        // Walk-in booking, checks in first thing in the morning, no known checkout.
        let a = hotel("Walk-in booking", checkIn: instant(2026, 7, 20, 9, 0), checkOut: nil)
        // Second booking, checks in that afternoon — genuinely collides with
        // the walk-in's claimed night ([09:00, midnight the 21st)).
        let b = hotel("Afternoon booking", checkIn: instant(2026, 7, 20, 15, 0), checkOut: instant(2026, 7, 22, 11, 0))
        let conflicts = StayConflicts.conflicts(in: [a, b])
        XCTAssertEqual(conflicts.count, 1, "walk-in's claimed night [09:00, midnight) genuinely overlaps the 15:00 check-in")
    }

    func testNonHotelItemsNeverProduceAConflictEvenWhenTheirDatesOverlap() {
        let flightA = TestFixtures.makeItineraryItem(
            category: .flight, title: "Flight A", startsAt: instant(2026, 7, 20, 9, 0), endsAt: instant(2026, 7, 20, 12, 0),
            tz: "Asia/Bangkok"
        )
        let flightB = TestFixtures.makeItineraryItem(
            category: .flight, title: "Flight B", startsAt: instant(2026, 7, 20, 9, 0), endsAt: instant(2026, 7, 20, 12, 0),
            tz: "Asia/Bangkok"
        )
        XCTAssertTrue(StayConflicts.conflicts(in: [flightA, flightB]).isEmpty)
    }

    /// The whole point of resolving nights via `startLocalDay`/`endLocalDay`
    /// instead of comparing raw `Date` instants: a late-evening check-in in
    /// a zone ahead of UTC can fall on the *next* UTC calendar day while
    /// still being the *same* local night — comparing raw instants' UTC
    /// day would wrongly call this pair a conflict.
    func testCalendarNightsAreComparedInEachItemsOwnZoneNotRawUTCInstants() {
        // 2026-07-20 23:30 EDT == 2026-07-21 03:30 UTC, but the stay's own
        // (New York) local night is still the 20th.
        let lateCheckIn = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Late check-in",
            startsAt: instant(2026, 7, 20, 23, 30, tz: "America/New_York"), endsAt: nil, tz: "America/New_York"
        )
        // Raw UTC instant also falls on the 21st (12:00 UTC) — a naive
        // "same UTC calendar day" comparison would collide with the item
        // above; the real local nights (20th vs 21st) do not.
        let nextMorning = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Next check-in",
            startsAt: instant(2026, 7, 21, 8, 0, tz: "America/New_York"), endsAt: nil, tz: "America/New_York"
        )
        XCTAssertTrue(StayConflicts.conflicts(in: [lateCheckIn, nextMorning]).isEmpty)
    }

    // MARK: - Ordering / "first offending card"

    /// `conflicts.first?.firstId` is what `ItineraryTabView` scrolls to as
    /// "the first offending card" — it must be the earliest-starting
    /// FLAGGED stay, not simply the earliest item in the input array (an
    /// earlier, non-conflicting stay must not shadow it), and must not
    /// depend on input order.
    func testConflictsFirstIdentifiesTheEarliestStartingFlaggedStayRegardlessOfInputOrder() {
        let standalone = hotel("Solo night", checkIn: instant(2026, 7, 1, 14, 0), checkOut: instant(2026, 7, 3, 11, 0))
        let earlierOfThePair = hotel("Overlap A", checkIn: instant(2026, 7, 10, 14, 0), checkOut: instant(2026, 7, 16, 11, 0))
        let laterOfThePair = hotel("Overlap B", checkIn: instant(2026, 7, 10, 15, 0), checkOut: instant(2026, 7, 16, 12, 0))

        let conflicts = StayConflicts.conflicts(in: [laterOfThePair, standalone, earlierOfThePair])
        XCTAssertEqual(conflicts.first?.firstId, earlierOfThePair.id)
    }

    // MARK: - flaggedItemIds / otherHotelName

    func testFlaggedItemIdsIncludesBothSidesOfEveryConflict() {
        let a = hotel("A", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 26, 11, 0))
        let b = hotel("B", checkIn: instant(2026, 7, 20, 15, 0), checkOut: instant(2026, 7, 26, 12, 0))
        let conflicts = StayConflicts.conflicts(in: [a, b])
        XCTAssertEqual(StayConflicts.flaggedItemIds(in: conflicts), Set([a.id, b.id]))
    }

    func testOtherHotelNameNamesTheStayOnTheOtherSideOfTheConflict() {
        let a = hotel("Pullman Bangkok", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 26, 11, 0))
        let b = hotel("M\u{f6}venpick Khao Yai", checkIn: instant(2026, 7, 20, 15, 0), checkOut: instant(2026, 7, 26, 12, 0))
        let conflicts = StayConflicts.conflicts(in: [a, b])
        XCTAssertEqual(StayConflicts.otherHotelName(for: a.id, in: conflicts), "M\u{f6}venpick Khao Yai")
        XCTAssertEqual(StayConflicts.otherHotelName(for: b.id, in: conflicts), "Pullman Bangkok")
    }

    func testOtherHotelNameIsNilForAnUnflaggedItem() {
        let unrelated = hotel("Solo", checkIn: instant(2026, 7, 1, 14, 0), checkOut: instant(2026, 7, 3, 11, 0))
        XCTAssertNil(StayConflicts.otherHotelName(for: unrelated.id, in: []))
    }

    // MARK: - Banner copy

    func testHeadlineSaysAllNightsForAFullOverlap() {
        let a = hotel("A", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 26, 11, 0))
        let b = hotel("B", checkIn: instant(2026, 7, 20, 15, 0), checkOut: instant(2026, 7, 26, 12, 0))
        guard let conflict = StayConflicts.conflicts(in: [a, b]).first else { return XCTFail("expected a conflict") }
        XCTAssertEqual(StayConflicts.headline(for: conflict), "Two stays overlap all 6 nights")
    }

    func testHeadlineOmitsAllForAPartialOverlap() {
        let a = hotel("A", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 26, 11, 0))
        let b = hotel("B", checkIn: instant(2026, 7, 24, 14, 0), checkOut: instant(2026, 7, 28, 11, 0))
        guard let conflict = StayConflicts.conflicts(in: [a, b]).first else { return XCTFail("expected a conflict") }
        XCTAssertEqual(StayConflicts.headline(for: conflict), "Two stays overlap 2 nights")
    }

    func testHeadlineSingularNightGrammar() {
        let a = hotel("A", checkIn: instant(2026, 7, 20, 14, 0), checkOut: nil)
        let b = hotel("B", checkIn: instant(2026, 7, 19, 14, 0), checkOut: instant(2026, 7, 22, 11, 0))
        guard let conflict = StayConflicts.conflicts(in: [a, b]).first else { return XCTFail("expected a conflict") }
        XCTAssertEqual(StayConflicts.headline(for: conflict), "Two stays overlap 1 night")
    }

    func testBodyNamesBothHotels() {
        let a = hotel("Pullman Bangkok", checkIn: instant(2026, 7, 20, 14, 0), checkOut: instant(2026, 7, 26, 11, 0))
        let b = hotel("M\u{f6}venpick Khao Yai", checkIn: instant(2026, 7, 20, 15, 0), checkOut: instant(2026, 7, 26, 12, 0))
        guard let conflict = StayConflicts.conflicts(in: [a, b]).first else { return XCTFail("expected a conflict") }
        let body = StayConflicts.body(for: conflict)
        XCTAssertTrue(body.contains("Pullman Bangkok"))
        XCTAssertTrue(body.contains("M\u{f6}venpick Khao Yai"))
    }

    // MARK: - Three-way chain overlap (overlap is not transitive)

    /// A overlaps B, B overlaps C, but A and C share no night at all —
    /// `conflicts(in:)` must report EXACTLY the two adjacent pairs and must
    /// not synthesize a third (A, C) pair just because both touch B.
    func testThreeHotelsChainOverlapReportsExactlyTheAdjacentPairsNotAToC() {
        let a = hotel("Hotel A", checkIn: instant(2026, 8, 1, 14, 0), checkOut: instant(2026, 8, 4, 11, 0)) // nights 1-3
        let b = hotel("Hotel B", checkIn: instant(2026, 8, 3, 14, 0), checkOut: instant(2026, 8, 6, 11, 0)) // nights 3-5
        let c = hotel("Hotel C", checkIn: instant(2026, 8, 5, 14, 0), checkOut: instant(2026, 8, 8, 11, 0)) // nights 5-7

        // Shuffled input — `conflicts(in:)` sorts internally, so the exact
        // pair list must not depend on it.
        let conflicts = StayConflicts.conflicts(in: [c, a, b])

        XCTAssertEqual(conflicts.count, 2, "expected exactly A-B and B-C, not a synthesized A-C")
        XCTAssertTrue(
            conflicts.contains { $0.firstId == a.id && $0.secondId == b.id && $0.sharedNights == 1 },
            "A and B should share exactly the night of the 3rd"
        )
        XCTAssertTrue(
            conflicts.contains { $0.firstId == b.id && $0.secondId == c.id && $0.sharedNights == 1 },
            "B and C should share exactly the night of the 5th"
        )
        XCTAssertFalse(
            conflicts.contains { Set([$0.firstId, $0.secondId]) == Set([a.id, c.id]) },
            "A and C never share a night and must not appear as a pair"
        )
    }

    // MARK: - Cross-timezone pairs (the Pacific date-line trap)
    //
    // Reviewer D2 (fixed): the overlap DECISION now compares each stay's
    // real booked window directly (`StayConflicts.decisionRange`, which
    // uses raw `startsAt`/`endsAt` whenever both are present), not bare
    // `DayDate` labels — two different IANA zones straddling the
    // international date line (Kiritimati UTC+14, Pago Pago UTC-11 — a
    // real 25h offset) can desync a same-looking label from actual
    // simultaneity in BOTH directions, a real overlap whose labels don't
    // match, and matching labels with no real overlap. Both scenarios
    // below are verified independently against real `Date` instants (not
    // just against `StayConflicts`' own math) before asserting what
    // `conflicts(in:)` does with them.

    /// B's real check-in/check-out window is entirely nested inside A's
    /// (proved below via raw instants) — an unambiguous, genuine overlap —
    /// even though A's own local night label reads "the 20th" while B's
    /// reads "the 19th".
    func testCrossTimezonePairWithGenuineOverlapAcrossTheDateLineIsFlagged() {
        let a = hotel(
            "Kiritimati stay", checkIn: instant(2026, 7, 20, 15, 0, tz: "Pacific/Kiritimati"),
            checkOut: instant(2026, 7, 21, 11, 0, tz: "Pacific/Kiritimati"), tz: "Pacific/Kiritimati"
        )
        let b = hotel(
            "Pago Pago stay", checkIn: instant(2026, 7, 19, 20, 0, tz: "Pacific/Pago_Pago"),
            checkOut: instant(2026, 7, 20, 8, 0, tz: "Pacific/Pago_Pago"), tz: "Pacific/Pago_Pago"
        )
        guard let bEnd = b.endsAt, let aEnd = a.endsAt else { return XCTFail("fixture requires both endsAt") }
        XCTAssertTrue(a.startsAt < bEnd && b.startsAt < aEnd, "sanity: B's absolute window is nested inside A's")

        XCTAssertFalse(StayConflicts.conflicts(in: [a, b]).isEmpty, "these stays truly overlap and must be flagged")
    }

    /// The mirror case: C and D's local night labels both read "the 20th",
    /// yet their real check-in/check-out windows (proved below) never
    /// intersect — a genuine 10-hour real gap — so this must NOT be
    /// flagged despite the matching labels.
    func testCrossTimezonePairWithNoRealOverlapAcrossTheDateLineIsNotFlagged() {
        let c = hotel(
            "Kiritimati stay", checkIn: instant(2026, 7, 20, 15, 0, tz: "Pacific/Kiritimati"),
            checkOut: instant(2026, 7, 21, 11, 0, tz: "Pacific/Kiritimati"), tz: "Pacific/Kiritimati"
        )
        let d = hotel(
            "Pago Pago stay", checkIn: instant(2026, 7, 20, 20, 0, tz: "Pacific/Pago_Pago"),
            checkOut: instant(2026, 7, 21, 8, 0, tz: "Pacific/Pago_Pago"), tz: "Pacific/Pago_Pago"
        )
        guard let cEnd = c.endsAt else { return XCTFail("fixture requires endsAt") }
        XCTAssertFalse(cEnd > d.startsAt, "sanity: C ends before D starts — a real 10-hour gap, no overlap")

        XCTAssertTrue(StayConflicts.conflicts(in: [c, d]).isEmpty, "these stays never really overlap and must not be flagged")
    }

    // MARK: - Cross-timezone same-day handoffs (eastward zone jump)
    //
    // The false positive this fix kills: the demo trip's own Lisbon ->
    // Madrid handoff (checkout 2026-05-21 11:00 Europe/Lisbon, check-in
    // 2026-05-21 15:00 Europe/Madrid, same calendar day) used to get
    // flagged, because the OLD decision compared each zone's LOCAL
    // MIDNIGHT for the 21st: Madrid (UTC+2 in May) hits its midnight an
    // hour before Lisbon (UTC+1) hits its own, manufacturing a phantom
    // 1-hour "overlap" between two midnights that never corresponded to
    // any moment either stay was actually booked. Comparing the real
    // `startsAt`/`endsAt` instants (`decisionRange`) fixes it: Lisbon's
    // real checkout (10:00 UTC) is hours before Madrid's real check-in
    // (13:00 UTC), so there is nothing to flag.

    /// The exact shape of `Support/DemoSeeder.swift`'s `hotels()` pair
    /// ("LX Boutique Hotel" / "Gran Meli\u{e1} Palacio de los Duques") — must
    /// render the demo trip clean, with no rose overlap flag on either card.
    func testEastwardCrossZoneSameDayHandoffIsNotFlagged() {
        let lisbon = hotel(
            "LX Boutique Hotel", checkIn: instant(2026, 5, 17, 15, 0, tz: "Europe/Lisbon"),
            checkOut: instant(2026, 5, 21, 11, 0, tz: "Europe/Lisbon"), tz: "Europe/Lisbon"
        )
        let madrid = hotel(
            "Gran Meli\u{e1} Palacio de los Duques", checkIn: instant(2026, 5, 21, 15, 0, tz: "Europe/Madrid"),
            checkOut: instant(2026, 5, 23, 11, 0, tz: "Europe/Madrid"), tz: "Europe/Madrid"
        )
        guard let lisbonEnd = lisbon.endsAt else { return XCTFail("fixture requires endsAt") }
        XCTAssertTrue(
            lisbonEnd <= madrid.startsAt,
            "sanity: Lisbon's real checkout (10:00 UTC) is before Madrid's real check-in (13:00 UTC) — a real 3h gap"
        )

        XCTAssertTrue(
            StayConflicts.conflicts(in: [lisbon, madrid]).isEmpty,
            "checkout precedes the next check-in by real hours — must not be flagged despite the shared calendar day"
        )
    }

    /// The mirror case: real windows that actually DO intersect on the same
    /// handoff day must still be flagged — this fix must not turn off
    /// overlap detection for cross-zone stays altogether, only the phantom
    /// midnight-label sliver.
    func testGenuineCrossZoneSameDayDoubleBookingIsStillFlagged() {
        let lisbon = hotel(
            "LX Boutique Hotel", checkIn: instant(2026, 5, 17, 15, 0, tz: "Europe/Lisbon"),
            checkOut: instant(2026, 5, 21, 18, 0, tz: "Europe/Lisbon"), tz: "Europe/Lisbon"
        )
        let madrid = hotel(
            "Gran Meli\u{e1} Palacio de los Duques", checkIn: instant(2026, 5, 21, 15, 0, tz: "Europe/Madrid"),
            checkOut: instant(2026, 5, 23, 11, 0, tz: "Europe/Madrid"), tz: "Europe/Madrid"
        )
        guard let lisbonEnd = lisbon.endsAt else { return XCTFail("fixture requires endsAt") }
        XCTAssertTrue(
            madrid.startsAt < lisbonEnd,
            "sanity: Madrid's real check-in (13:00 UTC) is before Lisbon's real checkout (17:00 UTC) — a real 4h overlap"
        )

        guard let conflict = StayConflicts.conflicts(in: [lisbon, madrid]).first else {
            return XCTFail("real windows genuinely overlap and must be flagged")
        }
        XCTAssertEqual(conflict.sharedNights, 1, "same-day cross-zone overlap still clamps to 1 shared night for copy")
    }

    // MARK: - DST transitions

    /// The shared-nights count must be pure calendar-day arithmetic,
    /// unaffected by a fall-back DST transition inside the overlap window
    /// (2026-11-01, America/New_York gains an extra real hour there) — a
    /// stay spanning it is still N calendar nights, not N \u{b1} 1 from
    /// naively dividing real elapsed hours by 24.
    func testSharedNightsAcrossAFallBackDSTTransitionIsPureCalendarArithmetic() {
        // Stay A: Oct 30 -> Nov 3 (nights 30, 31, 1, 2 = 4 nights).
        let a = hotel(
            "Long stay", checkIn: instant(2026, 10, 30, 15, 0, tz: "America/New_York"),
            checkOut: instant(2026, 11, 3, 11, 0, tz: "America/New_York"), tz: "America/New_York"
        )
        // Stay B: Oct 31 -> Nov 3 (nights 31, 1, 2 = 3 nights) — overlaps
        // A's tail, sharing exactly nights 31/1/2, straddling the Nov 1 ->
        // Nov 2 fall-back night (2026's US "clocks back" Sunday).
        let b = hotel(
            "Overlapping stay", checkIn: instant(2026, 10, 31, 15, 0, tz: "America/New_York"),
            checkOut: instant(2026, 11, 3, 12, 0, tz: "America/New_York"), tz: "America/New_York"
        )
        guard let conflict = StayConflicts.conflicts(in: [a, b]).first else { return XCTFail("expected a conflict") }
        XCTAssertEqual(conflict.sharedNights, 3, "31st/1st/2nd \u{2014} the DST fall-back night must still count as one night")
        XCTAssertFalse(conflict.isFullOverlap, "A has an extra night (the 30th) B doesn't share")
    }
}
