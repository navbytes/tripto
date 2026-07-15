import XCTest
@testable import Tripto

/// P4.1 (docs/UX_REDESIGN_ROADMAP.md): the inline role-chip `Menu` replaced
/// the separate `RolePickerSheet` — this pins `ShareTripView.roleMenuAction`,
/// the pure decision behind the `Picker` selection binding (organizer needs
/// the extra promote confirmation, everyone else changes immediately, and
/// re-selecting the current role is a no-op), without a live view or
/// `ModelContext`.
final class ShareTripViewRoleMenuTests: XCTestCase {
    func testSelectingTheCurrentRoleIsANoOp() {
        XCTAssertEqual(ShareTripView.roleMenuAction(selected: .companion, current: .companion), .none)
        XCTAssertEqual(ShareTripView.roleMenuAction(selected: .viewer, current: .viewer), .none)
        XCTAssertEqual(ShareTripView.roleMenuAction(selected: .organizer, current: .organizer), .none)
    }

    func testSelectingOrganizerRoutesThroughThePromoteConfirmation() {
        XCTAssertEqual(
            ShareTripView.roleMenuAction(selected: .organizer, current: .companion),
            .confirmPromoteToOrganizer
        )
        XCTAssertEqual(
            ShareTripView.roleMenuAction(selected: .organizer, current: .viewer),
            .confirmPromoteToOrganizer
        )
    }

    func testSelectingCompanionOrViewerChangesImmediately() {
        XCTAssertEqual(
            ShareTripView.roleMenuAction(selected: .companion, current: .viewer),
            .changeRoleImmediately(.companion)
        )
        XCTAssertEqual(
            ShareTripView.roleMenuAction(selected: .viewer, current: .organizer),
            .changeRoleImmediately(.viewer)
        )
        XCTAssertEqual(
            ShareTripView.roleMenuAction(selected: .companion, current: .organizer),
            .changeRoleImmediately(.companion)
        )
    }
}
