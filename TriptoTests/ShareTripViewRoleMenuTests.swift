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
        // The one (selected, current) pair the three hand-picked cases above
        // never exercised — caught by the exhaustive matrix test below;
        // pinned here too as its own explicit, minimal-repro case.
        XCTAssertEqual(
            ShareTripView.roleMenuAction(selected: .viewer, current: .companion),
            .changeRoleImmediately(.viewer)
        )
    }

    /// Exhaustive 3x3 grid over every `(selected, current)` `TripRole` pair —
    /// the individual-case tests above document *why* each bucket exists;
    /// this one guarantees the grid has no gaps (it originally had exactly
    /// one: `selected: .viewer, current: .companion` was never asserted).
    /// Scales automatically if `TripRole` ever grows a fourth case, unlike
    /// a hand-enumerated list.
    func testRoleMenuActionCoversTheFullSelectedByCurrentMatrixWithNoGaps() {
        for current in TripRole.allCases {
            for selected in TripRole.allCases {
                let expected: ShareTripView.RoleMenuAction
                if selected == current {
                    expected = .none
                } else if selected == .organizer {
                    expected = .confirmPromoteToOrganizer
                } else {
                    expected = .changeRoleImmediately(selected)
                }
                XCTAssertEqual(
                    ShareTripView.roleMenuAction(selected: selected, current: current), expected,
                    "selected: \(selected.rawValue), current: \(current.rawValue)"
                )
            }
        }
    }
}
