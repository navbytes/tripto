import XCTest
@testable import Tripto

/// P6.2 (docs/UX_REDESIGN_ROADMAP.md): `TripMergeDetection`'s pure
/// duplicate-trip matrix — dates, destination normalization, and the
/// adjacent-pair-only survivor scan. Foundation-only, no SwiftData;
/// `TripMergeTests` covers the SwiftData move.
final class TripMergeDetectionTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
    }

    private func trip(destination: String, start: Date, end: Date) -> Trip {
        TestFixtures.makeTrip(destination: destination, startDate: start, endDate: end)
    }

    // MARK: - isDuplicate matrix

    func testIdenticalDatesAndDestinationAreDuplicates() {
        let a = trip(destination: "Okinawa, Japan", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let b = trip(destination: "Okinawa, Japan", start: day(2026, 7, 22), end: day(2026, 7, 26))
        XCTAssertTrue(TripMergeDetection.isDuplicate(a, b, calendar: utc))
    }

    func testDestinationMatchIsCaseAndWhitespaceInsensitive() {
        let a = trip(destination: "  Okinawa, Japan ", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let b = trip(destination: "OKINAWA, JAPAN", start: day(2026, 7, 22), end: day(2026, 7, 26))
        XCTAssertTrue(TripMergeDetection.isDuplicate(a, b, calendar: utc))
    }

    func testDifferentStartDateIsNotADuplicate() {
        let a = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let b = trip(destination: "Okinawa", start: day(2026, 7, 23), end: day(2026, 7, 26))
        XCTAssertFalse(TripMergeDetection.isDuplicate(a, b, calendar: utc))
    }

    func testDifferentEndDateIsNotADuplicate() {
        let a = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let b = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 27))
        XCTAssertFalse(TripMergeDetection.isDuplicate(a, b, calendar: utc))
    }

    func testDifferentDestinationIsNotADuplicate() {
        let a = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let b = trip(destination: "Singapore", start: day(2026, 7, 22), end: day(2026, 7, 26))
        XCTAssertFalse(TripMergeDetection.isDuplicate(a, b, calendar: utc))
    }

    /// Two blank-destination trips with the same dates aren't necessarily
    /// the same place — same defensive caution as `TripCard.locationText`.
    func testTwoBlankDestinationsAreNeverConsideredDuplicates() {
        let a = trip(destination: "", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let b = trip(destination: "  ", start: day(2026, 7, 22), end: day(2026, 7, 26))
        XCTAssertFalse(TripMergeDetection.isDuplicate(a, b, calendar: utc))
    }

    // MARK: - survivorByShellId

    func testAdjacentDuplicatePairYieldsSecondCardPointingAtTheFirst() {
        let first = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let second = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let result = TripMergeDetection.survivorByShellId(in: [first, second], calendar: utc)
        XCTAssertEqual(result[second.id]?.id, first.id)
        XCTAssertNil(result[first.id], "the survivor itself is never its own shell")
    }

    /// Adjacent-pair only (the roadmap's own reasoning: identical-date
    /// trips are always neighbors in a soonest-start-first sort) — a
    /// same-dates trip separated by an unrelated one two rows away never
    /// pairs, even though it shares the same dates+destination.
    func testNonAdjacentSameDatesTripsSeparatedByAnUnrelatedTripDoNotPair() {
        let first = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let unrelated = trip(destination: "Singapore", start: day(2026, 8, 1), end: day(2026, 8, 5))
        let second = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let result = TripMergeDetection.survivorByShellId(in: [first, unrelated, second], calendar: utc)
        XCTAssertTrue(result.isEmpty, "adjacent-pair only — a same-dates trip two rows away never pairs")
    }

    /// A rare 3-way tie chains each card to the one directly above it,
    /// rather than needing a special multi-way case.
    func testThreeWayTieChainsEachCardToTheOneDirectlyAboveIt() {
        let a = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let b = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let c = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        let result = TripMergeDetection.survivorByShellId(in: [a, b, c], calendar: utc)
        XCTAssertEqual(result[b.id]?.id, a.id)
        XCTAssertEqual(result[c.id]?.id, b.id)
    }

    func testSingleTripListHasNoPairs() {
        let only = trip(destination: "Okinawa", start: day(2026, 7, 22), end: day(2026, 7, 26))
        XCTAssertTrue(TripMergeDetection.survivorByShellId(in: [only], calendar: utc).isEmpty)
    }

    func testEmptyListHasNoPairs() {
        XCTAssertTrue(TripMergeDetection.survivorByShellId(in: [], calendar: utc).isEmpty)
    }
}
