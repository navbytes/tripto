import XCTest
@testable import Tripto

/// M3 brief: "Role-change permission logic (only organizer can change
/// roles; can't change own; promote-to-organizer allowed) — pure function,
/// no network." Same "convenience only, RLS is the real boundary" caveat
/// as `ItemPermissionsTests`.
final class MemberRolePermissionsTests: XCTestCase {
    func testOrganizerCanChangeAnotherMembersRole() {
        XCTAssertTrue(MemberRolePermissions.canChangeRole(actingRole: .organizer, targetIsSelf: false))
    }

    func testOrganizerCannotChangeTheirOwnRole() {
        XCTAssertFalse(
            MemberRolePermissions.canChangeRole(actingRole: .organizer, targetIsSelf: true),
            "there is no self-demotion/self-promotion path in v1"
        )
    }

    func testCompanionCanNeverChangeAnyonesRole() {
        XCTAssertFalse(MemberRolePermissions.canChangeRole(actingRole: .companion, targetIsSelf: false))
        XCTAssertFalse(MemberRolePermissions.canChangeRole(actingRole: .companion, targetIsSelf: true))
    }

    func testViewerCanNeverChangeAnyonesRole() {
        XCTAssertFalse(MemberRolePermissions.canChangeRole(actingRole: .viewer, targetIsSelf: false))
        XCTAssertFalse(MemberRolePermissions.canChangeRole(actingRole: .viewer, targetIsSelf: true))
    }

    func testNoKnownRoleCanNeverChangeARole() {
        XCTAssertFalse(MemberRolePermissions.canChangeRole(actingRole: nil, targetIsSelf: false))
    }

    /// Promotion is just another role change under this gate — asserted as
    /// its own case since BUILD_PLAN's roles screen calls it out
    /// separately ("can also promote to Organizer with a confirm").
    func testOrganizerCanPromoteAnotherMemberToOrganizer() {
        XCTAssertTrue(MemberRolePermissions.canChangeRole(actingRole: .organizer, targetIsSelf: false))
    }
}
