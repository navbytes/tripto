import XCTest
@testable import Tripto

/// Time-zone default fix: a new itinerary item should default its zone to the
/// trip's dominant existing-item zone — so a Lisbon trip defaults to Lisbon
/// time, not the traveler's home/device clock (the "Hong Kong time on a
/// JFK→LIS flight" surprise three testers hit). It falls back to the device
/// zone only when the trip has no items yet.
final class NewItemZoneDefaultTests: XCTestCase {
    func testEmptyTripFallsBackToDeviceZone() {
        let zone = NewItemZoneDefault.zone(
            forExistingItemTzIdentifiers: [],
            device: TimeZone(identifier: "Asia/Hong_Kong")!
        )
        XCTAssertEqual(zone.identifier, "Asia/Hong_Kong")
    }

    func testMostFrequentZoneWins() {
        let zone = NewItemZoneDefault.zone(
            forExistingItemTzIdentifiers: ["Europe/Lisbon", "Europe/Lisbon", "America/New_York"],
            device: TimeZone(identifier: "Asia/Hong_Kong")!
        )
        XCTAssertEqual(zone.identifier, "Europe/Lisbon",
                       "the zone most items already use should be the default for the next one")
    }

    func testTieBreaksToFirstSeenNotDevice() {
        let zone = NewItemZoneDefault.zone(
            forExistingItemTzIdentifiers: ["Europe/Lisbon", "America/New_York"],
            device: TimeZone(identifier: "Asia/Hong_Kong")!
        )
        XCTAssertEqual(zone.identifier, "Europe/Lisbon")
    }

    func testUnknownIdentifiersAreIgnored() {
        let zone = NewItemZoneDefault.zone(
            forExistingItemTzIdentifiers: ["Not/AZone", "Europe/Lisbon"],
            device: TimeZone(identifier: "UTC")!
        )
        XCTAssertEqual(zone.identifier, "Europe/Lisbon",
                       "a malformed stored identifier must not win or force the device fallback")
    }
}
