import XCTest
@testable import Tripto

/// "Just mine" filtering (BUILD_PLAN.md §5.4, this milestone's brief §3) —
/// pure logic, no SwiftData/network (`PersonFilter`'s own doc comment).
final class PersonFilterTests: XCTestCase {
    func testEveryoneSelectionReturnsAllItemsUnfiltered() {
        let itemA = TestFixtures.makeItineraryItem(startsAt: .now)
        let itemB = TestFixtures.makeItineraryItem(startsAt: .now)
        let result = PersonFilter.filteredItems([itemA, itemB], assignees: [], selectedProfileId: nil)
        XCTAssertEqual(result.map(\.id), [itemA.id, itemB.id])
    }

    /// "default: none = everyone" (this milestone's brief) — an unassigned
    /// item is for everyone, so filtering to one specific person must not
    /// hide it.
    func testItemWithNoAssigneesStaysVisibleUnderAnyFilter() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        let someone = UUID()
        let result = PersonFilter.filteredItems([item], assignees: [], selectedProfileId: someone)
        XCTAssertEqual(result.map(\.id), [item.id])
    }

    func testItemAssignedToSomeoneElseIsExcluded() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let grandma = UUID()
        let assignees = [ItemAssignee(itemId: item.id, profileId: grandma)]
        let result = PersonFilter.filteredItems([item], assignees: assignees, selectedProfileId: meera)
        XCTAssertTrue(result.isEmpty)
    }

    func testItemAssignedToTheSelectedPersonIsIncluded() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let assignees = [ItemAssignee(itemId: item.id, profileId: meera)]
        let result = PersonFilter.filteredItems([item], assignees: assignees, selectedProfileId: meera)
        XCTAssertEqual(result.map(\.id), [item.id])
    }

    func testItemWithMultipleAssigneesIncludingSelectedPersonIsIncluded() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let grandma = UUID()
        let assignees = [
            ItemAssignee(itemId: item.id, profileId: grandma),
            ItemAssignee(itemId: item.id, profileId: meera),
        ]
        let result = PersonFilter.filteredItems([item], assignees: assignees, selectedProfileId: meera)
        XCTAssertEqual(result.map(\.id), [item.id])
    }

    func testMixedTripFiltersToOnlyRelevantAndUnassignedItems() {
        let flight = TestFixtures.makeItineraryItem(startsAt: .now) // unassigned = for everyone
        let napTime = TestFixtures.makeItineraryItem(startsAt: .now)
        let carRental = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let organizer = UUID()
        let assignees = [
            ItemAssignee(itemId: napTime.id, profileId: meera),
            ItemAssignee(itemId: carRental.id, profileId: organizer),
        ]
        let result = PersonFilter.filteredItems(
            [flight, napTime, carRental], assignees: assignees, selectedProfileId: meera
        )
        XCTAssertEqual(Set(result.map(\.id)), [flight.id, napTime.id])
    }

    // MARK: - assigneeProfileIds

    func testAssigneeProfileIdsGroupsByItemAndRespectsItemIdScope() {
        let itemInScope = UUID()
        let itemOutOfScope = UUID()
        let profile1 = UUID()
        let profile2 = UUID()
        let assignees = [
            ItemAssignee(itemId: itemInScope, profileId: profile1),
            ItemAssignee(itemId: itemInScope, profileId: profile2),
            ItemAssignee(itemId: itemOutOfScope, profileId: profile1),
        ]
        let result = PersonFilter.assigneeProfileIds(assignees, itemIds: [itemInScope])
        XCTAssertEqual(Set(result[itemInScope] ?? []), [profile1, profile2])
        XCTAssertNil(result[itemOutOfScope], "an item outside the given scope must not appear at all")
    }

    func testAssigneeProfileIdsIsEmptyWhenNothingIsAssigned() {
        XCTAssertTrue(PersonFilter.assigneeProfileIds([], itemIds: [UUID()]).isEmpty)
    }
}
