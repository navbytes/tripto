import Foundation
import SwiftData

/// P6.2's SwiftData-touching half (mirrors `HomeDuplication`'s split off
/// `TripDuplication`): moves a duplicate "shell" trip's itinerary items,
/// packing list, and trip profiles into the "survivor" trip it duplicates.
/// `HomeView` deletes the shell trip afterward via its own existing
/// `delete(_:)` cascade (trip + `trip_members` + any remaining
/// `trip_profiles` — none remain once this has run, so that cascade is a
/// no-op for profiles specifically) — unchanged, so there's exactly one
/// trip-delete code path in this app.
///
/// nt lesson YEFXVP / `HomeDuplication`'s own doc comment: the local mirror
/// is TRIP-SCOPED — itinerary items/packing enter it only via `pullTrip`,
/// never `pullHome`. A shell trip surfaced purely from Home metadata (date
/// range + destination) may never have been opened this session, so its
/// rows can be entirely absent locally; the survivor may be in the exact
/// same state (it's just as plausible the SURVIVOR — not just the shell —
/// was never opened either). Both are pulled (`ensureBothLoaded`, injected
/// so tests can drive it with `SyncStore.apply*` directly, no network)
/// before anything is read, so neither side of the merge can silently act
/// on an empty local set.
enum TripMerge {
    struct Moved {
        var items: [ItineraryItem]
        var packing: [PackingItem]
        var profiles: [TripProfile]
    }

    /// `nil` only if the save itself threw (caller surfaces the failure);
    /// empty arrays are a legitimate result (an itemless shell trip is still
    /// a valid, if pointless, thing to merge away).
    @MainActor
    static func execute(
        shellTripId: UUID,
        survivorTripId: UUID,
        modelContext: ModelContext,
        ensureBothLoaded: () async -> Void
    ) async -> Moved? {
        await ensureBothLoaded()

        let items = (try? modelContext.fetch(FetchDescriptor<ItineraryItem>(
            predicate: #Predicate<ItineraryItem> { $0.tripId == shellTripId }
        ))) ?? []
        let packing = (try? modelContext.fetch(FetchDescriptor<PackingItem>(
            predicate: #Predicate<PackingItem> { $0.tripId == shellTripId }
        ))) ?? []
        let profiles = (try? modelContext.fetch(FetchDescriptor<TripProfile>(
            predicate: #Predicate<TripProfile> { $0.tripId == shellTripId }
        ))) ?? []

        // Re-point in place (not delete-then-recreate): these rows keep
        // their own identity/history, only their `trip_id` changes — the
        // same "one field flips, one upsert enqueued" shape every other
        // reassignment in this app uses (e.g. `ShareTripView.changeRole`).
        for item in items { item.tripId = survivorTripId }
        for packingItem in packing { packingItem.tripId = survivorTripId }
        for profile in profiles { profile.tripId = survivorTripId }

        do {
            try modelContext.save()
        } catch {
            return nil
        }
        return Moved(items: items, packing: packing, profiles: profiles)
    }
}
