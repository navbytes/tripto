import Foundation

/// Client-side convenience mirror of ACCEPTANCE.md "(b)"'s roles matrix for
/// changing a `trip_members` row's role from `ShareTripView`'s people list
/// — same "never the real security boundary" caveat as `ItemPermissions`
/// (CLAUDE.md: RLS enforces this server-side).
enum MemberRolePermissions {
    /// Only the organizer may change a role, and never their own (there is
    /// no self-demotion/self-promotion path in v1 — ACCEPTANCE.md "(b)":
    /// "Change a member's role: yes organizer / no companion / no viewer",
    /// and the people list never offers the picker on the viewer's own row).
    /// This is also the exact gate for **promoting** someone to organizer —
    /// it's just another role change, not a separately-permissioned action.
    static func canChangeRole(actingRole: TripRole?, targetIsSelf: Bool) -> Bool {
        guard !targetIsSelf else { return false }
        return actingRole == .organizer
    }
}
