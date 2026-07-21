import XCTest
@testable import Tripto

/// ACCEPTANCE.md "(b)"'s roles matrix, client-side convenience mirror
/// (`ItemPermissions`'s own doc comment — never the real security
/// boundary, RLS is).
final class ItemPermissionsTests: XCTestCase {
    func testOrganizerCanEditAnyItemRegardlessOfWhoCreatedIt() {
        let creator = UUID()
        let organizer = UUID()
        let item = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: creator)
        XCTAssertTrue(ItemPermissions.canEdit(item: item, role: .organizer, userId: organizer))
    }

    func testCompanionCanEditOnlyTheirOwnItem() {
        let me = UUID()
        let someoneElse = UUID()
        let myItem = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: me)
        let theirItem = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: someoneElse)

        XCTAssertTrue(ItemPermissions.canEdit(item: myItem, role: .companion, userId: me))
        XCTAssertFalse(
            ItemPermissions.canEdit(item: theirItem, role: .companion, userId: me),
            "a companion must never restructure another member's item (§5.1)"
        )
    }

    func testViewerCanNeverEditEvenTheirOwnItem() {
        let me = UUID()
        let item = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: me)
        XCTAssertFalse(ItemPermissions.canEdit(item: item, role: .viewer, userId: me))
    }

    func testNoKnownRoleCanNeverEdit() {
        let me = UUID()
        let item = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: me)
        XCTAssertFalse(ItemPermissions.canEdit(item: item, role: nil, userId: me))
    }

    func testDeleteAndNotesEditingMirrorTheSameRule() {
        let me = UUID()
        let someoneElse = UUID()
        let theirItem = TestFixtures.makeItineraryItem(startsAt: .now, createdBy: someoneElse)

        XCTAssertEqual(
            ItemPermissions.canDelete(item: theirItem, role: .companion, userId: me),
            ItemPermissions.canEdit(item: theirItem, role: .companion, userId: me)
        )
        XCTAssertEqual(
            ItemPermissions.canEditNotes(item: theirItem, role: .organizer, userId: me),
            ItemPermissions.canEdit(item: theirItem, role: .organizer, userId: me)
        )
    }

    func testCanAddIsOrganizerOrCompanionOnly() {
        XCTAssertTrue(ItemPermissions.canAdd(role: .organizer))
        XCTAssertTrue(ItemPermissions.canAdd(role: .companion))
        XCTAssertFalse(ItemPermissions.canAdd(role: .viewer))
        XCTAssertFalse(ItemPermissions.canAdd(role: nil))
    }

    func testCanSuggestIsViewerOnly() {
        XCTAssertFalse(ItemPermissions.canSuggest(role: .organizer))
        XCTAssertFalse(ItemPermissions.canSuggest(role: .companion))
        XCTAssertTrue(ItemPermissions.canSuggest(role: .viewer))
        XCTAssertFalse(ItemPermissions.canSuggest(role: nil))
    }

    func testCanReviewSuggestionIsOrganizerOrCompanionOnly() {
        XCTAssertTrue(ItemPermissions.canReviewSuggestion(role: .organizer))
        XCTAssertTrue(ItemPermissions.canReviewSuggestion(role: .companion))
        XCTAssertFalse(
            ItemPermissions.canReviewSuggestion(role: .viewer),
            "a viewer must never see confirm/dismiss on a suggestion, including their own"
        )
        XCTAssertFalse(ItemPermissions.canReviewSuggestion(role: nil))
    }
}
