import XCTest
@testable import Tripto

/// BRIEF (app-intents deepening): `TripEntityQuery`/`BookingEntityQuery`'s
/// snapshot -> entity-option mapping (`TripEntityOptions`/`BookingEntityOptions`,
/// `IntentSupport.swift`), against a fixture `TripSnapshot` — no
/// `EntityQuery`/Siri machinery involved, same discipline as every other
/// pure builder in this file's family (`NextUpDialogTests`).
final class IntentEntityOptionsTests: XCTestCase {
    // MARK: - TripEntityOptions

    func testTripOptionsIsEmptyForNoSnapshot() {
        XCTAssertTrue(TripEntityOptions.options(from: nil).isEmpty)
    }

    func testTripOptionsMapsEverySnapshotTripInOrder() {
        let lisbon = makeTrip(title: "Lisbon")
        let rome = makeTrip(title: "Rome")
        let snapshot = TripSnapshot(generatedAt: .now, trips: [lisbon, rome], focusTripItems: [])

        let options = TripEntityOptions.options(from: snapshot)

        XCTAssertEqual(options.map(\.id), [lisbon.id, rome.id])
        XCTAssertEqual(options.map(\.title), ["Lisbon", "Rome"])
    }

    // MARK: - BookingEntityOptions

    /// Only flight/hotel/transport are offered — activity/food are excluded
    /// even when present, since the snapshot carries no reservation-marker
    /// field (`confirmation`/`details.ticketRef`) that could tell a real
    /// booking apart from a plain sightseeing stop (BRIEF decision).
    func testBookingOptionsIncludesOnlyFlightHotelAndTransport() {
        let flight = makeItem(category: .flight, title: "TAP TP1234")
        let hotel = makeItem(category: .hotel, title: "Hotel Lisboa")
        let transport = makeItem(category: .transport, title: "Airport transfer")
        let activity = makeItem(category: .activity, title: "Belem tour")
        let food = makeItem(category: .food, title: "Dinner")
        let snapshot = TripSnapshot(generatedAt: .now, trips: [], focusTripItems: [flight, hotel, transport, activity, food])

        let options = BookingEntityOptions.options(from: snapshot)

        XCTAssertEqual(Set(options.map(\.id)), Set([flight.id, hotel.id, transport.id]))
    }

    func testBookingOptionsIsEmptyForNoSnapshot() {
        XCTAssertTrue(BookingEntityOptions.options(from: nil).isEmpty)
    }

    func testBookingOptionsIsEmptyWhenFocusTripHasNoBookingCategoryItems() {
        let snapshot = TripSnapshot(generatedAt: .now, trips: [], focusTripItems: [makeItem(category: .activity, title: "Belem tour")])
        XCTAssertTrue(BookingEntityOptions.options(from: snapshot).isEmpty)
    }

    // MARK: - Fixtures

    private func makeTrip(title: String) -> SnapshotTrip {
        SnapshotTrip(id: UUID(), title: title, coverGradient: "dusk", startDate: .now, endDate: .now, destination: "Somewhere")
    }

    private func makeItem(category: SnapshotItem.Category, title: String) -> SnapshotItem {
        SnapshotItem(
            id: UUID(), tripId: UUID(), title: title, category: category,
            startsAt: .now, endsAt: nil, tz: "UTC",
            fromIATA: nil, toIATA: nil, flightNo: nil, locationName: ""
        )
    }
}
