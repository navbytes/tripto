import XCTest
@testable import Tripto

/// Assigning/unassigning a person on an item (this milestone's brief §3:
/// "Assigning happens in AddItemSheet/BookingDetail...") shares
/// `itinerary_items`' own edit rule — confirmed live against the
/// `item_assignees_insert`/`_delete` RLS policies: "organizer OR (companion
/// AND ii.created_by = auth.uid())", the identical predicate
/// `ItemPermissions.canEdit` already encodes (`AddItemSheet.canManageAssignees`
/// reuses it directly rather than reintroducing a separate, looser
/// organizer-or-companion rule that would let a companion assign people on
/// items they don't own — a real gap the live RLS query for this milestone
/// caught). This milestone's brief §5: "assignment permission gating
/// (viewer can't; companion can)."
final class ItemAssigneePermissionsTests: XCTestCase {
    func testCompanionCanAssignOnAnItemTheyCreated() {
        let me = UUID()
        let myItem = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: me)
        XCTAssertTrue(ItemPermissions.canEdit(item: myItem, role: .companion, userId: me))
    }

    func testCompanionCannotAssignOnSomeoneElsesItem() {
        let me = UUID()
        let someoneElse = UUID()
        let theirItem = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: someoneElse)
        XCTAssertFalse(
            ItemPermissions.canEdit(item: theirItem, role: .companion, userId: me),
            "a companion may not assign people on an item they didn't create"
        )
    }

    func testViewerCanNeverAssignEvenOnTheirOwnItem() {
        // Impossible in practice (viewers can't create items at all), but
        // the rule itself must not depend on that being enforced elsewhere.
        let me = UUID()
        let item = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: me)
        XCTAssertFalse(ItemPermissions.canEdit(item: item, role: .viewer, userId: me))
    }

    func testOrganizerCanAssignOnAnyItemRegardlessOfCreator() {
        let organizer = UUID()
        let item = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: UUID())
        XCTAssertTrue(ItemPermissions.canEdit(item: item, role: .organizer, userId: organizer))
    }

    func testNoKnownRoleCanNeverAssign() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: UUID())
        XCTAssertFalse(ItemPermissions.canEdit(item: item, role: nil, userId: UUID()))
    }
}
