import XCTest
@testable import Tripto

/// Feature A (adoption onboarding) hermetic checks — SampleTrip's fixture is
/// standalone/side-effect-free (A1), and TripFormView's trip-type choice is
/// visibly exposed with Friends leading (A2). Both properties are pure
/// model/data checks, no SwiftData context or network required, matching
/// this repo's existing "construct directly, assert on values" convention
/// (see TestFixtures.swift).
final class AdoptionOnboardingTests: XCTestCase {
    // MARK: - A1: SampleTrip fixture

    func testSampleTripIsAFriendsTrip() {
        XCTAssertEqual(SampleTrip.trip.tripType, .friends)
    }

    func testSampleTripHasNoOwnerOrNetworkDependency() {
        // Building the fixture at all (no auth, no ModelContainer, no
        // SyncEngine in scope for this test target) is the real assertion —
        // reading its values back just confirms it isn't an empty stub.
        XCTAssertFalse(SampleTrip.trip.title.isEmpty)
        XCTAssertFalse(SampleTrip.people.isEmpty)
        XCTAssertGreaterThanOrEqual(SampleTrip.people.count, 2)
    }

    func testSampleTripItemsCoverFlightStayAndActivities() {
        let categories = Set(SampleTrip.items.map(\.category))
        XCTAssertTrue(categories.contains(.flight))
        XCTAssertTrue(categories.contains(.hotel))
        XCTAssertEqual(SampleTrip.items.filter { $0.category == .activity }.count, 2)
        // All items belong to the same in-memory trip — never mixed with a
        // real trip id.
        XCTAssertTrue(SampleTrip.items.allSatisfy { $0.tripId == SampleTrip.trip.id })
    }

    func testSampleTripHasAPackingItem() {
        XCTAssertEqual(SampleTrip.packingItem.tripId, SampleTrip.trip.id)
        XCTAssertFalse(SampleTrip.packingItem.label.isEmpty)
    }

    func testSampleTripTeaserTextMentionsEveryItemAndThePackingItem() {
        for item in SampleTrip.items {
            XCTAssertTrue(SampleTrip.teaserText.contains(item.title))
        }
        XCTAssertTrue(SampleTrip.teaserText.contains(SampleTrip.packingItem.label))
    }

    func testSampleTripStartsInTheFutureSoItReadsAsUpcoming() {
        XCTAssertGreaterThan(SampleTrip.trip.startDate, Date())
    }

    // MARK: - A2: trip type is a deliberate, visible choice (not a silent default)

    func testTripTypeOptionsExposeAllThreeTypes() {
        XCTAssertEqual(Set(TripFormView.tripTypeOptions), Set(TripType.allCases))
    }

    func testFriendsLeadsTheTripTypeOptionOrder() {
        XCTAssertEqual(TripFormView.tripTypeOptions.first, .friends)
    }
}
