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

    /// State machine for the sanitized preview of a pending invite (inviter,
    /// trip, dates, role), fetched via `peek_invite` the moment a link arrives
    /// while signed out, so `WelcomeView` can show what you're joining BEFORE
    /// Sign in with Apple (usability dry-run: the handshake was otherwise
    /// blind — a bare optional couldn't tell "still loading" apart from
    /// "loaded nothing," so `WelcomeView` had no way to render an honest
    /// state for either).
    enum InvitePreviewState: Equatable {
        case idle
        case loading
        case loaded(InvitePreview)
        /// Fetch failed for a reason that isn't the invite itself being dead
        /// (offline, decode failure, `peek_invite` returning null) — the
        /// token is kept so sign-in and the post-sign-in claim still work.
        case unavailable
        /// The invite itself is dead (matched `Self.isInvalidInvite`) —
        /// `pendingInviteToken` is cleared alongside this so the user isn't
        /// walked through Apple account creation for a link that can't work.
        case invalid
    }

    private(set) var invitePreviewState: InvitePreviewState = .idle

    /// Set once `claim_invite` succeeds — `HomeView` observes this, pulls
    /// home, pushes the trip, and clears it back to nil via `clearTripToOpen()`.
    private(set) var tripToOpen: UUID?

    /// Set when a claim fails for a reason worth telling the user about —
    /// `HomeView` surfaces this as a persistent alert and clears it via
    /// `clearErrorToast()`.
    private(set) var errorToast: String?

    /// True for the span of a `claim(token:)` call — `HomeView`'s "Joining
    /// trip…" indicator (finding 6), so an invited user isn't staring at a
    /// static empty/loaded screen while the claim RPC is in flight. Ended by
    /// the two existing terminal calls below (`clearTripToOpen`/
    /// `clearErrorToast`), which already run at exactly claim's success and
    /// failure ends — no new choreography needed.
    private(set) var isJoiningTrip = false

    /// Entry point for `.onOpenURL`. Not an invite link (including the
    /// `/t/` share path) → no-op. Signed in → claim immediately. Signed out
    /// → stash for `claimPendingInviteIfNeeded()` to pick up post-sign-in.
    func handleIncoming(url: URL, isSignedIn: Bool) {
        guard let token = DeepLink.inviteToken(from: url) else { return }
        if isSignedIn {
            Task { await claim(token: token) }
        } else {
            pendingInviteToken = token
            Task { await fetchInvitePreview(token: token) }
        }
    }

    /// Sanitized preview fetch for the WelcomeView. Drives `invitePreviewState`
    /// through `.loading` -> `.loaded`/`.unavailable`/`.invalid` so the screen
    /// can render an honest state at every step instead of going blind on
    /// failure.
    private func fetchInvitePreview(token: String) async {
        invitePreviewState = .loading
        do {
            let preview: InvitePreview = try await Supa.rpc("peek_invite", params: PeekInviteParams(inviteToken: token))
            invitePreviewState = .loaded(preview)
        } catch {
            if Self.isInvalidInvite(error) {
                invitePreviewState = .invalid
                pendingInviteToken = nil
            } else {
                // Offline, decode failure, or `peek_invite` returning null for
                // an unknown/expired token (it doesn't raise 'invalid_invite'
                // the way `claim_invite` does) — keep the token so sign-in and
                // the post-sign-in claim can still try.
                invitePreviewState = .unavailable
            }
        }
    }

    /// `HomeView` calls this every time it appears — a cheap no-op when
    /// nothing's pending — so a token stashed while signed out gets
    /// claimed the moment a session exists.
    func claimPendingInviteIfNeeded() async {
        guard let token = pendingInviteToken else { return }
        pendingInviteToken = nil
        invitePreviewState = .idle
        await claim(token: token)
    }

    func clearTripToOpen() {
        tripToOpen = nil
        isJoiningTrip = false
    }

    func clearErrorToast() {
        errorToast = nil
        isJoiningTrip = false
    }

    /// `WelcomeView`'s "Try again" on the `.unavailable` invite-preview
    /// card. Guarded to `.unavailable` (with a token still stashed) so a
    /// double-tap or a call from the wrong state is a no-op — the state
    /// machine's existing `.loading` -> resolved re-render does the rest.
    func retryInvitePreview() {
        guard invitePreviewState == .unavailable, let token = pendingInviteToken else { return }
        Task { await fetchInvitePreview(token: token) }
    }

    #if DEBUG
    /// Verify-drill only: seed a mock invite preview so the pre-sign-in card can
    /// be screenshotted without a live two-user invite flow.
    func debugInjectInvitePreview(_ preview: InvitePreview) { invitePreviewState = .loaded(preview) }
    #endif

    private func claim(token: String) async {
        isJoiningTrip = true
        do {
            let tripId: UUID = try await Supa.rpc("claim_invite", params: ClaimInviteParams(inviteToken: token))
            // Guard (M3 brief): claiming an invite for a trip you're already
            // in is a no-op server-side (never downgrades an existing
            // organizer) and returns the same trip id — this just navigates,
            // exactly like a fresh join, with no error path to special-case.
            tripToOpen = tripId
        } catch {
            // §6.6 "what happened + how to fix it" — upgraded from the old
            // bare "try the link again" (finding 6).
            errorToast = Self.isInvalidInvite(error)
                ? "That invite link has expired or been revoked. Ask the trip organizer to send a new link."
                : "We couldn\u{2019}t join the trip \u{2014} check your connection, then open the link again."
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

private struct PeekInviteParams: Encodable {
    let inviteToken: String
}

/// Sanitized `peek_invite` payload — inviter display name, trip summary, and
/// role, with no email/token/ids (backend `peek_invite`). Decoded via the
/// shared `.convertFromSnakeCase` decoder, so these stay camelCase.
struct InvitePreview: Decodable, Equatable {
    let role: String
    let tripTitle: String
    let startDate: String
    let endDate: String
    let coverGradient: String
    let inviterName: String

    /// Formats `startDate`/`endDate` ("yyyy-MM-dd") as e.g. "May 14 – 27",
    /// locale-aware ordering via `Date.FormatStyle` (`TripCard.swift:123`'s
    /// idiom). Hides the year for an ordinary same-year trip; shows it on
    /// both ends when either date's year differs from `currentYear` — which
    /// also covers a trip that spans two years itself, since at least one
    /// end must then differ from `currentYear`. Falls back to the raw
    /// strings if either isn't a parseable date. `currentYear`/`locale` are
    /// injectable so this is unit-testable without depending on today's
    /// date or the device's locale.
    static func formattedDateRange(
        startDate: String,
        endDate: String,
        currentYear: Int = Calendar.current.component(.year, from: .now),
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        guard let startDay = DayDate.parse(startDate), let endDay = DayDate.parse(endDate) else {
            return "\(startDate) \u{2013} \(endDate)"
        }
        let showYear = startDay.year != currentYear || endDay.year != currentYear
        var style = Date.FormatStyle(locale: locale).month(.abbreviated).day()
        if showYear { style = style.year() }
        return "\(startDay.asDate().formatted(style)) \u{2013} \(endDay.asDate().formatted(style))"
    }
}
