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
}
