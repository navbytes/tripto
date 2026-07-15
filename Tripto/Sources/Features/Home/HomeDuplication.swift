import Foundation
import SwiftData

/// The SwiftData half of "Duplicate trip" (E2, docs/BACKLOG.md §E2) —
/// `TripDuplication` owns the pure rebase/clone math (Foundation-only, no
/// context); this owns the one part that has to touch the local mirror:
/// gathering the source trip's rows, then inserting the clones. Split out of
/// `HomeView.duplicateContent` (a `View` method, untestable) so the fetch-then-
/// clone step is directly unit-testable, the same house pattern `HomeRegisters`
/// already follows.
///
/// D1 (qa): the source rows MUST be pulled before they're read. `pullHome`
/// only fetches the home-scope tables (trips/members/profiles) — itinerary
/// items and packing enter the local mirror solely via `pullTrip`, which runs
/// only when a trip is opened (`SyncEngine+Pull`/`TripView`). So a past trip
/// duplicated straight from Home without being opened this session has ZERO
/// local items; reading them directly (as this code used to) cloned an empty
/// set and the empty-source guard reported success anyway — an itemless copy
/// whose "FIRST UP" strip is permanently absent, persisting across relaunch.
/// `ensureSourceLoaded` (in production `syncEngine.pullTrip(sourceTripId)`)
/// closes that gap; injected as a closure so tests can drive it with the same
/// `SyncStore.applyItineraryItems` a real pull applies, no network.
enum HomeDuplication {
    /// Fetched-and-cloned rows for the new trip, already inserted+saved on
    /// `modelContext`. `nil` means the save threw (caller surfaces the
    /// failure); empty arrays mean the source genuinely had nothing to clone
    /// (still a success — an empty trip is a valid, if pointless, template).
    struct Cloned {
        var items: [ItineraryItem]
        var packing: [PackingItem]
    }

    @MainActor
    static func cloneContent(
        sourceTripId: UUID,
        sourceStart: Date,
        newTripId: UUID,
        newStart: Date,
        createdBy: UUID,
        modelContext: ModelContext,
        now: Date = Date(),
        ensureSourceLoaded: () async -> Void
    ) async -> Cloned? {
        // Pull the source trip's rows into the local mirror first — see this
        // enum's doc comment (D1). No-op once they're already cached.
        await ensureSourceLoaded()

        let sourceItems = (try? modelContext.fetch(FetchDescriptor<ItineraryItem>(
            predicate: #Predicate<ItineraryItem> { $0.tripId == sourceTripId }
        ))) ?? []
        let sourcePacking = (try? modelContext.fetch(FetchDescriptor<PackingItem>(
            predicate: #Predicate<PackingItem> { $0.tripId == sourceTripId }
        ))) ?? []
        guard !sourceItems.isEmpty || !sourcePacking.isEmpty else { return Cloned(items: [], packing: []) }

        let dayDelta = TripDuplication.dayDelta(from: sourceStart, to: newStart)
        let clonedItems = TripDuplication.clonedItems(
            from: sourceItems, newTripId: newTripId, dayDelta: dayDelta, createdBy: createdBy, now: now
        )
        let clonedPacking = TripDuplication.clonedPackingItems(
            from: sourcePacking, newTripId: newTripId, createdBy: createdBy, now: now
        )

        for item in clonedItems { modelContext.insert(item) }
        for packingItem in clonedPacking { modelContext.insert(packingItem) }
        do {
            try modelContext.save()
        } catch {
            return nil
        }
        return Cloned(items: clonedItems, packing: clonedPacking)
    }
}
