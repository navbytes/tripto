import XCTest
@testable import Tripto

/// PLAN-signature-layer.md §D6 (W2-B): pins the pure decision logic behind
/// the travel-day Live Activity — selection, the 8h start window, the 45m
/// post-departure grace period, and the display-string fallbacks.
/// `evaluate()`'s ActivityKit side effects (`Activity.request`/`.end`)
/// aren't exercised here — no headless-unit-test runtime for those; see
/// W2-B.md for how that half was verified live in simulator.
final class LiveActivityCoordinatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - nextFlight

    func testNextFlightPicksSoonestFutureFlightOnly() {
        let past = makeItem(category: .flight, startsAt: now.addingTimeInterval(-3600))
        let soon = makeItem(category: .flight, startsAt: now.addingTimeInterval(1800))
        let later = makeItem(category: .flight, startsAt: now.addingTimeInterval(7200))
        let hotel = makeItem(category: .hotel, startsAt: now.addingTimeInterval(600))
        XCTAssertEqual(LiveActivityCoordinator.nextFlight(in: [past, later, hotel, soon], now: now)?.id, soon.id)
    }

    func testNextFlightNilWithNoUpcomingFlights() {
        let past = makeItem(category: .flight, startsAt: now.addingTimeInterval(-60))
        XCTAssertNil(LiveActivityCoordinator.nextFlight(in: [past], now: now))
    }

    func testNextFlightNilWhenEmpty() {
        XCTAssertNil(LiveActivityCoordinator.nextFlight(in: [], now: now))
    }

    // MARK: - shouldStart

    func testShouldStartTrueWithinWindowAndNotRunning() {
        let flight = makeItem(category: .flight, startsAt: now.addingTimeInterval(3600))
        XCTAssertTrue(LiveActivityCoordinator.shouldStart(flight: flight, runningItemIds: [], now: now))
    }

    func testShouldStartTrueAtExactlyEightHours() {
        // Closed upper bound: exactly 8h out is still fair game.
        let flight = makeItem(category: .flight, startsAt: now.addingTimeInterval(8 * 3600))
        XCTAssertTrue(LiveActivityCoordinator.shouldStart(flight: flight, runningItemIds: [], now: now))
    }

    func testShouldStartFalseBeyondEightHourWindow() {
        let flight = makeItem(category: .flight, startsAt: now.addingTimeInterval(8 * 3600 + 1))
        XCTAssertFalse(LiveActivityCoordinator.shouldStart(flight: flight, runningItemIds: [], now: now))
    }

    func testShouldStartFalseWhenAlreadyRunning() {
        let flight = makeItem(category: .flight, startsAt: now.addingTimeInterval(3600))
        XCTAssertFalse(LiveActivityCoordinator.shouldStart(flight: flight, runningItemIds: [flight.id], now: now))
    }

    func testShouldStartFalseOncePastDeparture() {
        let flight = makeItem(category: .flight, startsAt: now.addingTimeInterval(-1))
        XCTAssertFalse(LiveActivityCoordinator.shouldStart(flight: flight, runningItemIds: [], now: now))
    }

    // MARK: - itemIdsToEnd

    func testItemIdsToEndOnlyPastGracePeriod() {
        let staleId = UUID()
        let freshId = UUID()
        let departures: [UUID: Date] = [
            staleId: now.addingTimeInterval(-46 * 60), // departed 46m ago, past the 45m grace
            freshId: now.addingTimeInterval(-10 * 60) // departed 10m ago, still within grace
        ]
        XCTAssertEqual(LiveActivityCoordinator.itemIdsToEnd(runningDepartures: departures, now: now), [staleId])
    }

    func testItemIdsToEndEmptyWhenNothingRunning() {
        XCTAssertEqual(LiveActivityCoordinator.itemIdsToEnd(runningDepartures: [:], now: now), [])
    }

    // MARK: - routeText / flightName

    func testRouteTextPrefersIATAPair() {
        let item = makeItem(category: .flight, startsAt: now, fromIATA: "JFK", toIATA: "LIS")
        XCTAssertEqual(LiveActivityCoordinator.routeText(for: item), "JFK \u{2192} LIS")
    }

    func testRouteTextFallsBackToLocationNameWithoutIATA() {
        let item = makeItem(category: .flight, startsAt: now, locationName: "JFK")
        XCTAssertEqual(LiveActivityCoordinator.routeText(for: item), "JFK")
    }

    func testFlightNamePrefersFlightNo() {
        let item = makeItem(category: .flight, startsAt: now, title: "TAP TP1234", flightNo: "TP1234")
        XCTAssertEqual(LiveActivityCoordinator.flightName(for: item), "TP1234")
    }

    func testFlightNameFallsBackToTitleWithoutFlightNo() {
        let item = makeItem(category: .flight, startsAt: now, title: "Mystery flight", flightNo: nil)
        XCTAssertEqual(LiveActivityCoordinator.flightName(for: item), "Mystery flight")
    }

    // MARK: - Helpers

    private func makeItem(
        category: SnapshotItem.Category, startsAt: Date, title: String = "Flight",
        fromIATA: String? = nil, toIATA: String? = nil, flightNo: String? = "TP1234", locationName: String = "JFK"
    ) -> SnapshotItem {
        SnapshotItem(
            id: UUID(), tripId: UUID(), title: title, category: category,
            startsAt: startsAt, endsAt: nil, tz: "America/New_York",
            fromIATA: fromIATA, toIATA: toIATA, flightNo: flightNo, locationName: locationName
        )
    }
}
