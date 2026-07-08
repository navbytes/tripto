import XCTest
@testable import Tripto

/// Flight arrival-after-departure validation: `AddItemSheet.isValid`'s
/// `.flight` case only checked `fromIATA`/`toIATA` were non-empty, so a user
/// who toggled the "+1 day" chip off with an arrival clock-time earlier than
/// departure could save a negative-duration flight. `AddItemSheet.flightInstants`
/// composes start/end exactly like `flightFields()` does (mirroring
/// `transportInstants`/`TransportMultiDayTests`' shape) — pure, no
/// SwiftData/network involved.
final class FlightTimeValidationTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let lisbon = TimeZone(identifier: "Europe/Lisbon")!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func time(_ h: Int, _ min: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: min, second: 0, of: Date())!
    }

    /// Same-day, arrival clock before departure, "+1 day" chip off — must
    /// not be a valid (positive-duration) flight.
    func testSameDayArrivalBeforeDepartureWithoutNextDayIsInvalid() {
        let (start, end) = AddItemSheet.flightInstants(
            flightDate: day(2026, 7, 8),
            departsTime: time(14, 0), departureZone: lisbon,
            arrivesTime: time(10, 0), arrivalZone: lisbon,
            nextDay: false
        )
        XCTAssertLessThanOrEqual(
            end, start,
            "an earlier same-day arrival with no +1 day chip must not be a valid, positive-duration flight"
        )
    }

    /// Red-eye: arrival clock before departure, but the "+1 day" chip is on
    /// — a genuine overnight flight, must be valid.
    func testRedEyeWithNextDayChipOnIsValid() {
        let (start, end) = AddItemSheet.flightInstants(
            flightDate: day(2026, 7, 8),
            departsTime: time(23, 0), departureZone: lisbon,
            arrivesTime: time(6, 0), arrivalZone: lisbon,
            nextDay: true
        )
        XCTAssertGreaterThan(end, start, "a red-eye with the +1 day chip on must be a valid, positive-duration flight")
    }

    /// Depart Tokyo 17:00 JST (UTC+9) -> 08:00 UTC. Arrive Los Angeles 10:00
    /// PDT (UTC-7) the *same calendar day* -> 17:00 UTC. Arrival wall-clock
    /// (10:00) is earlier than departure wall-clock (17:00), but the instant
    /// is 9 hours later — must be valid with no "+1 day" chip. Proves
    /// `flightEndAfterStart`/`flightInstants` compare absolute instants, not
    /// wall-clock times.
    func testWestwardCrossZoneSameDayIsValidByInstantNotWallClock() {
        let (start, end) = AddItemSheet.flightInstants(
            flightDate: day(2026, 7, 8),
            departsTime: time(17, 0), departureZone: tokyo,
            arrivesTime: time(10, 0), arrivalZone: losAngeles,
            nextDay: false
        )
        XCTAssertGreaterThan(end, start, "a real cross-zone flight can have an earlier arrival wall-clock yet a later instant")
        XCTAssertEqual(end.timeIntervalSince(start) / 3600, 9, accuracy: 0.01)
    }

    /// Equal instants (identical time, same zone, no offset) — a
    /// zero-duration flight must not be valid.
    func testEqualInstantsAreInvalid() {
        let (start, end) = AddItemSheet.flightInstants(
            flightDate: day(2026, 7, 8),
            departsTime: time(10, 0), departureZone: lisbon,
            arrivesTime: time(10, 0), arrivalZone: lisbon,
            nextDay: false
        )
        XCTAssertEqual(start, end)
        XCTAssertFalse(end > start, "a zero-duration flight (equal instants) must not be valid")
    }
}
