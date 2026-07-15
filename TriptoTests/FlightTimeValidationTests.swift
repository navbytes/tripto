import XCTest
@testable import Tripto

/// Flight arrival-after-departure validation: `AddItemSheet.isValid`'s
/// `.flight` case only checked `fromIATA`/`toIATA` were non-empty, so a user
/// with an arrival clock-time earlier than departure could save a
/// negative-duration flight. `AddItemSheet.flightInstants` composes
/// start/end exactly like `flightFields()` does (mirroring
/// `transportInstants`/`TransportMultiDayTests`' shape) — pure, no
/// SwiftData/network involved.
///
/// P7c (award audit #4): `flightInstants` used to take a single shared
/// `flightDate` plus a boolean `nextDay` (0 or +1 day only, defaulted from a
/// wall-clock-only guess blind to either zone). It now takes two independent
/// date+time+zone triples — the same "no day-offset toggle" shape
/// `transportInstants` already used for pickup/drop-off — so any day gap,
/// including the pathological +2-day case a late departure plus a large
/// eastbound zone gain can need, is directly representable instead of
/// guessed. The JFK->LIS cases below chain into `BoardingPassMath` (the
/// pass's own duration/day-badge math) to pin the form's UTC instants
/// produce exactly what the live preview would show.
final class FlightTimeValidationTests: XCTestCase {
    private let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private let losAngeles = TimeZone(identifier: "America/Los_Angeles")!
    private let lisbon = TimeZone(identifier: "Europe/Lisbon")!
    private let newYork = TimeZone(identifier: "America/New_York")!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func time(_ h: Int, _ min: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: min, second: 0, of: Date())!
    }

    /// Same-day, arrival clock before departure, arrival date left on the
    /// same day — must not be a valid (positive-duration) flight.
    func testSameDayArrivalBeforeDepartureIsInvalid() {
        let (start, end) = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(14, 0), departureZone: lisbon,
            arrivalDate: day(2026, 7, 8), arrivesTime: time(10, 0), arrivalZone: lisbon
        )
        XCTAssertLessThanOrEqual(
            end, start,
            "an earlier same-day arrival with no arrival-date change must not be a valid, positive-duration flight"
        )
    }

    /// Red-eye: arrival clock before departure, arrival date explicitly set
    /// to the next day — a genuine overnight flight, must be valid.
    func testRedEyeWithArrivalDateSetToNextDayIsValid() {
        let (start, end) = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(23, 0), departureZone: lisbon,
            arrivalDate: day(2026, 7, 9), arrivesTime: time(6, 0), arrivalZone: lisbon
        )
        XCTAssertGreaterThan(end, start, "a red-eye with arrival date set to the next day must be a valid, positive-duration flight")
    }

    /// Depart Tokyo 17:00 JST (UTC+9) -> 08:00 UTC. Arrive Los Angeles 10:00
    /// PDT (UTC-7) the *same calendar day* -> 17:00 UTC. Arrival wall-clock
    /// (10:00) is earlier than departure wall-clock (17:00), but the instant
    /// is 9 hours later — must be valid with the arrival date left unchanged.
    /// Proves `flightEndAfterStart`/`flightInstants` compare absolute
    /// instants, not wall-clock times.
    func testWestwardCrossZoneSameDayIsValidByInstantNotWallClock() {
        let (start, end) = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(17, 0), departureZone: tokyo,
            arrivalDate: day(2026, 7, 8), arrivesTime: time(10, 0), arrivalZone: losAngeles
        )
        XCTAssertGreaterThan(end, start, "a real cross-zone flight can have an earlier arrival wall-clock yet a later instant")
        XCTAssertEqual(end.timeIntervalSince(start) / 3600, 9, accuracy: 0.01)
    }

    /// Equal instants (identical time, same zone, same date) — a
    /// zero-duration flight must not be valid.
    func testEqualInstantsAreInvalid() {
        let (start, end) = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(10, 0), departureZone: lisbon,
            arrivalDate: day(2026, 7, 8), arrivesTime: time(10, 0), arrivalZone: lisbon
        )
        XCTAssertEqual(start, end)
        XCTAssertFalse(end > start, "a zero-duration flight (equal instants) must not be valid")
    }

    // MARK: - JFK -> LIS (the audited route): UTC-instant duration/day-offset

    /// A 9am JFK departure lands in Lisbon the *same* local day — this is
    /// the exact route the award audit's live-pass screenshots used (this
    /// milestone's real duration, ~6h55m), with arrival date left unchanged.
    /// Chains into `BoardingPassMath` to pin that the form's own instants
    /// produce the same duration/no-badge the live pass would show.
    func testJFKToLISNineAMDepartureLandsSameLocalDayWithNoDayBadge() {
        let (start, end) = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(9, 0), departureZone: newYork,
            arrivalDate: day(2026, 7, 8), arrivesTime: time(20, 55), arrivalZone: lisbon
        )
        XCTAssertGreaterThan(end, start)
        XCTAssertEqual(end.timeIntervalSince(start), 6 * 3600 + 55 * 60, accuracy: 1)
        XCTAssertEqual(BoardingPassMath.dayOffset(departure: start, departureTz: newYork, arrival: end, arrivalTz: lisbon), 0)
        XCTAssertNil(BoardingPassMath.dayBadgeText(departure: start, departureTz: newYork, arrival: end, arrivalTz: lisbon))
    }

    /// A late-night (23:00) JFK departure needs the arrival *date* actually
    /// moved to the next day to land validly — leaving it on the same day
    /// (what a single shared date + no day-offset would default to) is
    /// invalid. This is the exact "late JFK->LIS lands +1" case the award
    /// audit's zone-blind auto-suggest used to get wrong.
    func testLateNightJFKDepartureNeedsArrivalDateMovedToNextDay() {
        let sameDayEnd = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(23, 0), departureZone: newYork,
            arrivalDate: day(2026, 7, 8), arrivesTime: time(10, 55), arrivalZone: lisbon
        )
        XCTAssertLessThanOrEqual(sameDayEnd.end, sameDayEnd.start, "same-day arrival must not be valid for this departure")

        let (start, end) = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(23, 0), departureZone: newYork,
            arrivalDate: day(2026, 7, 9), arrivesTime: time(10, 55), arrivalZone: lisbon
        )
        XCTAssertGreaterThan(end, start, "moving arrival date to the next day must make this a valid flight")
        XCTAssertEqual(end.timeIntervalSince(start), 6 * 3600 + 55 * 60, accuracy: 1)
        XCTAssertEqual(BoardingPassMath.dayOffset(departure: start, departureTz: newYork, arrival: end, arrivalTz: lisbon), 1)
    }

    /// The pathological case the award audit flagged as inexpressible by a
    /// boolean "+1 day" chip: a departure late enough (23:30) that even the
    /// next calendar day isn't enough — only advancing the arrival date a
    /// full +2 days reaches a valid, positive-duration flight. A single
    /// 0-or-1 day-offset toggle has no way to represent this; an explicit
    /// arrival date picker does.
    func testPathologicalCaseNeedsArrivalDateSetTwoDaysLater() {
        let plusOneDay = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(23, 30), departureZone: newYork,
            arrivalDate: day(2026, 7, 9), arrivesTime: time(0, 15), arrivalZone: lisbon
        )
        XCTAssertLessThanOrEqual(plusOneDay.end, plusOneDay.start, "+1 day is not enough for this departure")

        let (start, end) = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(23, 30), departureZone: newYork,
            arrivalDate: day(2026, 7, 10), arrivesTime: time(0, 15), arrivalZone: lisbon
        )
        XCTAssertGreaterThan(end, start, "+2 days must reach a valid, positive-duration flight")
        XCTAssertEqual(end.timeIntervalSince(start), 19 * 3600 + 45 * 60, accuracy: 1)
        XCTAssertEqual(BoardingPassMath.dayOffset(departure: start, departureTz: newYork, arrival: end, arrivalTz: lisbon), 2)
        XCTAssertEqual(BoardingPassMath.dayBadgeText(departure: start, departureTz: newYork, arrival: end, arrivalTz: lisbon), "+2d")
    }

    /// Same-zone (domestic) flight: no zone math to account for, so the
    /// duration is exactly the wall-clock difference.
    func testSameZoneFlightDurationIsThePlainWallClockDifference() {
        let (start, end) = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 8), departsTime: time(10, 0), departureZone: newYork,
            arrivalDate: day(2026, 7, 8), arrivesTime: time(12, 30), arrivalZone: newYork
        )
        XCTAssertEqual(end.timeIntervalSince(start), 2 * 3600 + 30 * 60, accuracy: 1)
        XCTAssertEqual(BoardingPassMath.dayOffset(departure: start, departureTz: newYork, arrival: end, arrivalTz: newYork), 0)
    }

    /// An arrival *date* before the departure date — only reachable now that
    /// arrival has its own independent date picker (the old single shared
    /// date + 0/1 offset couldn't even represent this input) — must be
    /// rejected just like any other reversed input, not wrap around.
    func testArrivalDateBeforeDepartureDateIsRejected() {
        let (start, end) = AddItemSheet.flightInstants(
            departureDate: day(2026, 7, 10), departsTime: time(9, 0), departureZone: lisbon,
            arrivalDate: day(2026, 7, 9), arrivesTime: time(20, 0), arrivalZone: lisbon
        )
        XCTAssertLessThan(end, start, "an arrival calendar date before the departure date must not be a valid, positive-duration flight")
    }
}
