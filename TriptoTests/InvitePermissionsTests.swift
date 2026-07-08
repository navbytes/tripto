import XCTest
@testable import Tripto

/// M3 brief: "Active-invite filtering (revoked/expired excluded)."
final class InvitePermissionsTests: XCTestCase {
    private func makeInvite(revoked: Bool, expiresAt: Date, token: String = "abc123") -> Invite {
        Invite(
            id: UUID(), tripId: UUID(), token: token, roleRaw: TripRole.companion.rawValue,
            createdBy: UUID(), createdAt: .now, expiresAt: expiresAt, revoked: revoked
        )
    }

    func testActiveInviteIsNotRevokedAndNotExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let invite = makeInvite(revoked: false, expiresAt: now.addingTimeInterval(3600))
        XCTAssertTrue(InvitePermissions.isActive(invite, now: now))
    }

    func testRevokedInviteIsExcludedEvenIfNotExpired() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let invite = makeInvite(revoked: true, expiresAt: now.addingTimeInterval(3600))
        XCTAssertFalse(InvitePermissions.isActive(invite, now: now))
    }

    func testExpiredInviteIsExcludedEvenIfNotRevoked() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let invite = makeInvite(revoked: false, expiresAt: now.addingTimeInterval(-1))
        XCTAssertFalse(InvitePermissions.isActive(invite, now: now))
    }

    func testActiveInvitesFiltersOutRevokedAndExpiredButKeepsActive() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let active = makeInvite(revoked: false, expiresAt: now.addingTimeInterval(3600), token: "active")
        let revoked = makeInvite(revoked: true, expiresAt: now.addingTimeInterval(3600), token: "revoked")
        let expired = makeInvite(revoked: false, expiresAt: now.addingTimeInterval(-3600), token: "expired")

        let result = InvitePermissions.activeInvites([active, revoked, expired], now: now)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.token, "active")
    }
}
