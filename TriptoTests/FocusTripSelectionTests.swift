import XCTest
@testable import Tripto

/// BRIEF (app-intents deepening): `AddToPackingIntent`'s default-trip
/// selection — "in-progress else next upcoming" — extracted as
/// `FocusTripSelection.focusTrip(in:now:calendar:)` so every branch is
/// directly testable, same discipline as `NextUpDialogTests`. Fixed UTC
/// calendar/dates (that suite's own convention) so day-boundary branches
/// are deterministic regardless of the test machine's time zone.
final class FocusTripSelectionTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    private func trip(_ title: String, start: Date, end: Date) -> SnapshotTrip {
        SnapshotTrip(id: UUID(), title: title, coverGradient: "dusk", startDate: start, endDate: end, destination: "Somewhere")
    }

    func testEmptyListReturnsNil() {
        XCTAssertNil(FocusTripSelection.focusTrip(in: [], now: date(2027, 3, 1), calendar: calendar))
    }

    func testSingleUpcomingTripIsReturned() {
        let lisbon = trip("Lisbon", start: date(2027, 3, 14), end: date(2027, 3, 20))
        XCTAssertEqual(FocusTripSelection.focusTrip(in: [lisbon], now: date(2027, 3, 1), calendar: calendar)?.title, "Lisbon")
    }

    /// The in-progress trip wins regardless of its position in the array —
    /// this function must not lean on `TripSnapshot.trips`' own "in-progress
    /// sorts first" ordering invariant to get this right.
    func testInProgressTripWinsEvenWhenListedSecond() {
        let now = date(2027, 3, 16)
        let upcoming = trip("Rome", start: date(2027, 4, 1), end: date(2027, 4, 5))
        let inProgress = trip("Lisbon", start: date(2027, 3, 14), end: date(2027, 3, 20))
        XCTAssertEqual(FocusTripSelection.focusTrip(in: [upcoming, inProgress], now: now, calendar: calendar)?.title, "Lisbon")
    }

    func testNoneInProgressPicksSoonestUpcomingRegardlessOfListOrder() {
        let now = date(2027, 3, 1)
        let later = trip("Rome", start: date(2027, 4, 1), end: date(2027, 4, 5))
        let sooner = trip("Lisbon", start: date(2027, 3, 14), end: date(2027, 3, 20))
        XCTAssertEqual(FocusTripSelection.focusTrip(in: [later, sooner], now: now, calendar: calendar)?.title, "Lisbon")
    }

    /// A trip that's already ended must never win the "next upcoming"
    /// fallback just because its `startDate` happens to be earliest.
    func testPastTripIsExcludedFromTheUpcomingFallback() {
        let now = date(2027, 3, 25)
        let past = trip("Lisbon", start: date(2027, 3, 1), end: date(2027, 3, 10))
        let upcoming = trip("Rome", start: date(2027, 4, 1), end: date(2027, 4, 5))
        XCTAssertEqual(FocusTripSelection.focusTrip(in: [past, upcoming], now: now, calendar: calendar)?.title, "Rome")
    }

    func testOnlyPastTripsReturnsNil() {
        let now = date(2027, 3, 25)
        let past = trip("Lisbon", start: date(2027, 3, 1), end: date(2027, 3, 10))
        XCTAssertNil(FocusTripSelection.focusTrip(in: [past], now: now, calendar: calendar))
    }
}
