import Foundation
import Supabase

/// App-wide router for the one navigation concern that doesn't fit inside
/// `HomeView`'s own `NavigationPath`: an invite link arriving via
/// `.onOpenURL` (M3 brief), which can land before or after sign-in.
///
/// `TriptoApp` wires `.onOpenURL` to `handleIncoming` — the same real entry
/// point whether the URL comes from iOS actually opening a link or from
/// `xcrun simctl openurl` in the verify drill; nothing about URL delivery
/// is simulated. `HomeView` is the only screen guaranteed mounted once
/// signed in (`RootView`'s auth gate), so it drains `pendingInviteToken`
/// once at appear and reacts to `tripToOpen`/`errorToast` to actually
/// navigate/toast.
@Observable
@MainActor
final class AppRouter {
    /// Stashed when a `tripto://join/<token>` (or the universal-link
    /// equivalent) arrives while signed out. Claimed the first moment a
    /// session exists — "If NOT signed in → stash token, route to
    /// WelcomeView, claim after sign-in completes" (M3 brief).
    private(set) var pendingInviteToken: String?

    /// Set once `claim_invite` succeeds — `HomeView` observes this, pulls
    /// home, pushes the trip, and clears it back to nil via `clearTripToOpen()`.
    private(set) var tripToOpen: UUID?

    /// Set when a claim fails for a reason worth telling the user about —
    /// `HomeView` surfaces this as a toast and clears it via `clearErrorToast()`.
    private(set) var errorToast: String?

    /// Entry point for `.onOpenURL`. Not an invite link (including the
    /// `/t/` share path) → no-op. Signed in → claim immediately. Signed out
    /// → stash for `claimPendingInviteIfNeeded()` to pick up post-sign-in.
    func handleIncoming(url: URL, isSignedIn: Bool) {
        guard let token = DeepLink.inviteToken(from: url) else { return }
        if isSignedIn {
            Task { await claim(token: token) }
        } else {
            pendingInviteToken = token
        }
    }

    /// `HomeView` calls this every time it appears — a cheap no-op when
    /// nothing's pending — so a token stashed while signed out gets
    /// claimed the moment a session exists.
    func claimPendingInviteIfNeeded() async {
        guard let token = pendingInviteToken else { return }
        pendingInviteToken = nil
        await claim(token: token)
    }

    func clearTripToOpen() { tripToOpen = nil }
    func clearErrorToast() { errorToast = nil }

    private func claim(token: String) async {
        do {
            let tripId: UUID = try await Supa.rpc("claim_invite", params: ClaimInviteParams(inviteToken: token))
            // Guard (M3 brief): claiming an invite for a trip you're already
            // in is a no-op server-side (never downgrades an existing
            // organizer) and returns the same trip id — this just navigates,
            // exactly like a fresh join, with no error path to special-case.
            tripToOpen = tripId
        } catch {
            errorToast = Self.isInvalidInvite(error)
                ? "That invite link has expired or been revoked."
                : "Couldn\u{2019}t join that trip \u{2014} try the link again."
        }
    }

    /// `claim_invite`'s documented error strings arrive as a Postgres
    /// `RAISE EXCEPTION` message (M3 brief: "Errors: 'not_authenticated',
    /// 'invalid_invite'") — PostgREST surfaces that as `PostgrestError.message`
    /// verbatim; there's no distinct HTTP status to switch on instead.
    private static func isInvalidInvite(_ error: Error) -> Bool {
        if let postgrestError = error as? PostgrestError {
            return postgrestError.message.localizedCaseInsensitiveContains("invalid_invite")
        }
        return "\(error)".localizedCaseInsensitiveContains("invalid_invite")
    }
}

private struct ClaimInviteParams: Encodable {
    let inviteToken: String
}
