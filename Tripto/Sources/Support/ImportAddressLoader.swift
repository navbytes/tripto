import Foundation

/// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): the trip's email-import address —
/// load-once, consent-gated, tap-to-retry state machine. SOC finding F4
/// (structure review): the identical quartet (fetch-if-needed / fetch /
/// retry / grant-consent-and-fetch) plus its two `@State` properties used to
/// be re-hosted verbatim in `ItineraryTabView`, `AddItemSheet`, and
/// `ShareTripView` — no single type owned it. One instance per screen now
/// does (`@State private var importLoader = ImportAddressLoader()`, same
/// no-arg-default idiom `LocationSearchCompleter` already uses for
/// per-view `@Observable` helpers).
///
/// The three call sites differ only in their own permission gate (`canEdit`
/// vs `ItemPermissions.canAdd(role:)`) and where `tripId` comes from
/// (`trip.id` vs a stored `tripId`) — both threaded through as plain
/// parameters rather than copied into this type. Each view also keeps
/// owning its own `.task`/`.task(id:)` wiring (whether the one-shot fetch
/// needs to re-run on a later gate change is a per-screen concern, not this
/// type's).
@Observable
@MainActor
final class ImportAddressLoader {
    /// A5 (`docs/BACKLOG.md`) / Apple Guideline 5.1.2(i): starts
    /// `.needsConsent` instead of `.loading` when consent isn't on record
    /// yet (a synchronous `UserDefaults` read, evaluated once per screen
    /// visit) so a not-yet-consented user never sees a "Loading…" flash
    /// before the pre-consent card; `fetchIfNeeded` never overrides this
    /// back to `.loading` on its own — only `grantConsentAndFetch` does.
    private(set) var state: ImportAddressCard.LoadState = EmailImportConsent.isGranted() ? .loading : .needsConsent
    private var hasFetched = false

    /// One real fetch attempt per screen visit. `canFetch` is the caller's
    /// own permission gate, re-evaluated by the view every time its
    /// `.task`/`.task(id:)` fires; not-yet-consented leaves `state` exactly
    /// as `.needsConsent` and, critically, does NOT set `hasFetched`, so a
    /// later `grantConsentAndFetch` still gets its one real attempt.
    func fetchIfNeeded(tripId: UUID, canFetch: Bool) async {
        guard canFetch, !hasFetched else { return }
        guard EmailImportConsent.fetchDecision() == .fetchImmediately else { return }
        hasFetched = true
        await fetch(tripId: tripId)
    }

    /// The actual RPC call, split out so `retry` can re-run it without
    /// re-triggering `hasFetched`'s guard.
    private func fetch(tripId: UUID) async {
        do {
            state = .loaded(try await TripImportAddress.fetch(tripId: tripId))
        } catch {
            state = .failed
        }
    }

    /// `ImportAddressCard`'s tap-to-retry action on a `.failed` state.
    func retry(tripId: UUID) {
        state = .loading
        Task { await fetch(tripId: tripId) }
    }

    /// `ImportAddressCard`'s `.needsConsent` card -> `onConsentGranted` —
    /// the consent dialog's "Continue" button. `hasFetched` is set directly
    /// here rather than through `fetchIfNeeded` — that guard already ran
    /// once (and bailed on consent) for the screen's one-shot fetch; this is
    /// the deferred completion of that same single attempt, not a second one.
    func grantConsentAndFetch(tripId: UUID) {
        EmailImportConsent.grant()
        hasFetched = true
        retry(tripId: tripId)
    }
}
