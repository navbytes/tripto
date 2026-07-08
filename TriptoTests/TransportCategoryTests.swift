import XCTest
@testable import Tripto

/// The 5th item category (rental cars / trains / ferries / transfers), added
/// as a v1 scope expansion. Covers the enum, its display mapping, the two new
/// `ItemDetails` fields' codec round-trip, and the timeline subtitle.
final class TransportCategoryTests: XCTestCase {
    func testTransportCategoryRawRoundTrips() {
        XCTAssertEqual(ItemCategory(rawValue: "transport"), .transport)
        XCTAssertEqual(ItemCategory.transport.rawValue, "transport")
        XCTAssertTrue(ItemCategory.allCases.contains(.transport))
    }

    func testTransportDisplayNameAndIcon() {
        XCTAssertEqual(ItemCategory.transport.displayName, "Transport")
        XCTAssertEqual(ItemCategory.transport.symbolName, "car.fill")
    }

    func testProviderAndDropoffRoundTripThroughDetailsCodec() {
        var details = ItemDetails.empty
        details.provider = "Hertz"
        details.dropoffLocation = "Boston Logan"
        details.arrivalTz = "America/New_York" // drop-off zone reuses arrivalTz
        let decoded = ItemDetails(json: details.json)
        XCTAssertEqual(decoded.provider, "Hertz")
        XCTAssertEqual(decoded.dropoffLocation, "Boston Logan")
        XCTAssertEqual(decoded.arrivalTz, "America/New_York")
    }

    func testTransportSubtitleUsesProviderAndDropoff() {
        let item = TestFixtures.makeItineraryItem(
            category: .transport, title: "Rental car", startsAt: Date(),
            locationName: "Lisbon Airport",
            details: ItemDetails(provider: "Hertz", dropoffLocation: "Cambridge")
        )
        XCTAssertEqual(TimelineBuilder.subtitle(for: item), "Hertz · to Cambridge")
    }

    func testTransportSubtitleFallsBackToLocationThenLabel() {
        let withLocation = TestFixtures.makeItineraryItem(
            category: .transport, title: "Train", startsAt: Date(), locationName: "St Pancras"
        )
        XCTAssertEqual(TimelineBuilder.subtitle(for: withLocation), "St Pancras")

        let bare = TestFixtures.makeItineraryItem(
            category: .transport, title: "Transfer", startsAt: Date()
        )
        XCTAssertEqual(TimelineBuilder.subtitle(for: bare), "Transport")
    }
}
