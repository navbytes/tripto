import Foundation

/// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): thin wrapper around
/// `get_or_create_trip_import_address` — any trip member may call it. Shared
/// by `ItineraryTabView`'s `importTeaser` (empty-itinerary only) and
/// `ShareTripView`'s persistent `importCard`, which is why this moved out of
/// `ItineraryTabView` rather than staying private to it.
enum TripImportAddress {
    static func fetch(tripId: UUID) async throws -> String {
        try await Supa.rpc("get_or_create_trip_import_address", params: TripImportAddressParams(pTripId: tripId))
    }
}

/// `get_or_create_trip_import_address(p_trip_id uuid)` — see
/// `TripImportAddress.fetch(tripId:)`'s doc comment.
private struct TripImportAddressParams: Encodable {
    let pTripId: UUID
}

/// A5 (`docs/BACKLOG.md`) / Apple Guideline 5.1.2(i): explicit, affirmative
/// permission before a forwarded email is processed by a third-party AI.
/// Mirrors `AIImportConsent` (`PasteImportSheet.swift`) exactly in shape —
/// same injectable-`UserDefaults` recipe, same one-time-forever semantics —
/// but its own key: a past paste-import consent doesn't speak for email
/// forwarding (different disclosure scope: the raw email is retained
/// server-side for up to 7 days per `docs/EMAIL_IMPORT_PLAN.md`'s retention
/// decision, vs. paste's "isn't stored afterward"), and granting one must
/// never silently grant the other.
///
/// Paste-import gates a SEND action (the Import button); email import has no
/// in-app send moment (`docs/BACKLOG.md`'s A5) — a forwarded email is
/// processed the instant it lands, regardless of what the app is showing.
/// So this instead gates the ADDRESS FETCH: `TripImportAddress.fetch` is the
/// thing that reveals the address a user would actually forward to, and
/// `ImportAddressLoader.fetchIfNeeded` (shared by every call site — see that
/// type's own doc comment) checks `fetchDecision()` before calling it —
/// not-granted renders `ImportAddressCard`'s
/// `.needsConsent` state (explainer + "Show email address" button) instead.
/// That state's own confirmation dialog lives inside `ImportAddressCard`
/// itself (its `onConsentGranted` closure), not duplicated per call site,
/// since both surfaces share the exact same card and copy.
enum EmailImportConsent {
    private static let key = "emailImportConsentGranted"

    static func isGranted(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func grant(defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: key)
    }

    /// The address-fetch decision — `ImportAddressLoader.fetchIfNeeded`
    /// switches on this instead of fetching unconditionally.
    enum FetchDecision: Equatable {
        case fetchImmediately
        case needsConsent
    }

    static func fetchDecision(defaults: UserDefaults = .standard) -> FetchDecision {
        isGranted(defaults: defaults) ? .fetchImmediately : .needsConsent
    }
}
