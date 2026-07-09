import Foundation

/// Pure filtering rule for `ShareTripView`'s "active invites" list —
/// revoked or expired invite links are never shown as live/shareable, even
/// though their rows still exist locally/server-side (ACCEPTANCE.md "(b)":
/// "Claim an invite link: via link" implies a *valid* link; §5.1 invites
/// expire at `expires_at`, default +30d).
enum InvitePermissions {
    static func isActive(_ invite: Invite, now: Date = .now) -> Bool {
        !invite.revoked && invite.expiresAt > now
    }

    /// Preserves the input order (callers pass already-sorted invites).
    static func activeInvites(_ invites: [Invite], now: Date = .now) -> [Invite] {
        invites.filter { isActive($0, now: now) }
    }

    /// The single active invite of `role`, if one exists — invites are
    /// role-scoped **reusable** links (`claim_invite`, no single-use field),
    /// so re-sharing should surface the one already-active link per role
    /// rather than minting another (avoids duplicate/indistinguishable
    /// invite rows). `invites` need not be pre-sorted/pre-filtered.
    static func activeInvite(role: TripRole, in invites: [Invite], now: Date = .now) -> Invite? {
        invites.first { $0.role == role && isActive($0, now: now) }
    }
}
