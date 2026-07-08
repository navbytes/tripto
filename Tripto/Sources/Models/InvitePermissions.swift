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
}
