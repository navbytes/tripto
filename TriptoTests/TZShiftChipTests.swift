import XCTest
@testable import Tripto

/// The rail's tz-shift chip math (this milestone's brief; ACCEPTANCE.md
/// "(a)" point 3): the eastbound JFK→LIS jump BUILD_PLAN's own acceptance
/// case names, a half-hour zone (Asia/Kolkata, called out explicitly so a
/// naive `Int` rounding doesn't silently drop the ".5"), and the mirror
/// westbound "go back" direction.
final class TZShiftChipTests: XCTestCase {
    private func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return utc.date(from: components)!
    }

    private func makeFlight(depTz: String, arrTz: String, starts: Date, ends: Date) -> ItineraryItem {
        var details = ItemDetails.empty
        details.arrivalTz = arrTz
        return TestFixtures.makeItineraryItem(
            category: .flight, title: "Test flight", startsAt: starts, endsAt: ends, tz: depTz, details: details
        )
    }

    /// ACCEPTANCE.md "(a)" Case A1's exact flight: JFK 08:20 EDT -> LIS
    /// 20:15 WEST — eastbound, a 5h jump (WEST +1 minus EDT -4).
    func testEastboundJFKToLisbonJumpsAheadFiveHours() {
        let flight = makeFlight(
            depTz: "America/New_York", arrTz: "Europe/Lisbon",
            starts: utcInstant(2026, 5, 14, 12, 20), // 08:20 EDT
            ends: utcInstant(2026, 5, 14, 19, 15) // 20:15 WEST
        )
        XCTAssertEqual(TZShiftChip.landingText(for: flight), "Lands 20:15 in Lisbon — clocks jump ahead 5h")
    }

    /// A half-hour zone (Asia/Kolkata, UTC+5:30 year-round, no DST) must
    /// render "5.5", not "6" or a floating-point artifact — this
    /// milestone's brief calls this case out by name.
    func testHalfHourZoneRendersFiveAndAHalfHours() {
        let flight = makeFlight(
            depTz: "UTC", arrTz: "Asia/Kolkata",
            starts: utcInstant(2026, 5, 14, 0, 0), // 00:00 UTC
            ends: utcInstant(2026, 5, 14, 4, 0) // 04:00 UTC = 09:30 IST
        )
        XCTAssertEqual(TZShiftChip.landingText(for: flight), "Lands 09:30 in Kolkata — clocks jump ahead 5.5h")
    }

    /// Westbound — Lisbon back to New York — clocks "go back", the mirror
    /// direction of the outbound leg above.
    func testWestboundLisbonToNewYorkGoesBackFiveHours() {
        let flight = makeFlight(
            depTz: "Europe/Lisbon", arrTz: "America/New_York",
            starts: utcInstant(2026, 5, 27, 10, 0), // 11:00 WEST
            ends: utcInstant(2026, 5, 27, 18, 25) // 14:25 EDT
        )
        XCTAssertEqual(TZShiftChip.landingText(for: flight), "Lands 14:25 in New York — clocks go back 5h")
    }

    func testNoLandingChipWhenArrivalZoneMatchesDeparture() {
        let flight = makeFlight(
            depTz: "Europe/Lisbon", arrTz: "Europe/Lisbon",
            starts: utcInstant(2026, 6, 1, 12, 0), ends: utcInstant(2026, 6, 1, 14, 0)
        )
        XCTAssertNil(TZShiftChip.landingText(for: flight))
    }

    func testNoLandingChipForANonFlightCategory() {
        var details = ItemDetails.empty
        details.arrivalTz = "America/New_York" // nonsensical for a hotel, but proves the category guard alone suffices
        let hotel = TestFixtures.makeItineraryItem(
            category: .hotel, startsAt: utcInstant(2026, 6, 1, 12, 0), endsAt: utcInstant(2026, 6, 2, 12, 0),
            tz: "Europe/Lisbon", details: details
        )
        XCTAssertNil(TZShiftChip.landingText(for: hotel))
    }

    /// A non-flight crossing (e.g. a train from Lisbon to Madrid) that a
    /// landing chip never announced — `zoneChangeText` is what covers this.
    /// The abbreviation itself comes straight from `ItineraryTimeZone`'s own
    /// formatter rather than a hardcoded literal like "CEST" — Foundation's
    /// ICU data doesn't guarantee that exact classic abbreviation on every
    /// OS/ICU version (some report "GMT+2" instead); the city name and
    /// message shape are what this test actually verifies.
    func testZoneChangeTextFiresForANonFlightCrossing() {
        let madrid = TimeZone(identifier: "Europe/Madrid")!
        let nextStart = utcInstant(2026, 5, 21, 12, 0)
        let previous = TestFixtures.makeItineraryItem(
            category: .activity, startsAt: utcInstant(2026, 5, 21, 8, 0), tz: "Europe/Lisbon"
        )
        let next = TestFixtures.makeItineraryItem(category: .activity, startsAt: nextStart, tz: "Europe/Madrid")

        let expectedAbbreviation = ItineraryTimeZone.zoneLabel(for: madrid, at: nextStart)
        XCTAssertEqual(
            TZShiftChip.zoneChangeText(previous: previous, next: next),
            "Times now in Madrid (\(expectedAbbreviation))"
        )
    }

    /// Once a flight's landing chip already announced the new zone, the
    /// very next item in that same zone must not also trigger a redundant
    /// `zoneChangeText` — `effectiveTz` (arrival zone) is what `next`
    /// compares against, not the flight's own departure `tz`.
    func testZoneChangeTextIsNilWhenALandingChipAlreadyAnnouncedTheSameZone() {
        let flight = makeFlight(
            depTz: "America/New_York", arrTz: "Europe/Lisbon",
            starts: utcInstant(2026, 5, 14, 12, 20), ends: utcInstant(2026, 5, 14, 19, 15)
        )
        let hotel = TestFixtures.makeItineraryItem(
            category: .hotel, startsAt: utcInstant(2026, 5, 14, 20, 0), tz: "Europe/Lisbon"
        )
        XCTAssertNil(TZShiftChip.zoneChangeText(previous: flight, next: hotel))
    }

    func testFormatHoursTrimsWholeNumbersAndKeepsHalfHours() {
        XCTAssertEqual(TZShiftChip.formatHours(5.0), "5")
        XCTAssertEqual(TZShiftChip.formatHours(5.5), "5.5")
        XCTAssertEqual(TZShiftChip.formatHours(0.0), "0")
    }
}
