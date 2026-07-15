import Foundation
import SwiftData

/// P6.3 (docs/UX_REDESIGN_ROADMAP.md): within-ONE-trip traveller dedupe —
/// `TripProfile` rows on the SAME trip sharing a normalized display name.
/// Cross-trip traveller identity (recognizing the same person across
/// different trips) needs a person entity this app's schema doesn't have —
/// explicitly fenced, filed in docs/BACKLOG.md, not built here.
///
/// `TripProfile` carries no email column today (only the account-level
/// `Profile`, and even that has none — confirmed by reading both models),
/// so despite the roadmap's "name or email" phrasing, normalized display
/// name is the only field this can actually key off given the current
/// schema; a future `email` column would slot into `normalizedKey` as an
/// additional match without changing this type's shape.
///
/// One file, not split pure/impure like `TripMergeDetection`/`TripMerge` —
/// the impure half here is a handful of straight-line SwiftData calls (no
/// branching worth isolating for its own test matrix the way trip-merge's
/// adjacent-pair scan needed).
enum ProfileDedupe {
    /// One detected pair — `survivor` is the earlier-created profile of the
    /// two (an arbitrary but deterministic default; the review sheet
    /// doesn't ask the user to pick which one wins, matching the roadmap's
    /// "Merge/Keep both" — only two choices, not three).
    struct Pair: Identifiable {
        let survivor: TripProfile
        let duplicate: TripProfile
        var id: UUID { duplicate.id }
    }

    /// Trimmed + lowercased. Blank names are excluded from grouping
    /// entirely (an empty key would otherwise pair every no-name profile on
    /// a trip together).
    static func normalizedKey(_ profile: TripProfile) -> String {
        profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Every duplicate pair among `profiles` (expected to already be scoped
    /// to one trip — callers pass a trip-filtered `TripProfile` list, same
    /// as `ShareTripView`'s own `@Query`). A group of 3+ profiles sharing a
    /// name yields one pair per non-survivor, all pointing at the same
    /// (earliest) survivor — chosen deterministically so the UI/tests don't
    /// depend on dictionary-grouping order.
    static func duplicatePairs(in profiles: [TripProfile]) -> [Pair] {
        let groups = Dictionary(grouping: profiles) { normalizedKey($0) }
        var pairs: [Pair] = []
        for (key, group) in groups where !key.isEmpty && group.count > 1 {
            let sorted = group.sorted { $0.createdAt < $1.createdAt }
            guard let survivor = sorted.first else { continue }
            for duplicate in sorted.dropFirst() {
                pairs.append(Pair(survivor: survivor, duplicate: duplicate))
            }
        }
        return pairs.sorted { lhs, rhs in
            let lhsKey = normalizedKey(lhs.survivor)
            let rhsKey = normalizedKey(rhs.survivor)
            return lhsKey == rhsKey ? lhs.duplicate.createdAt < rhs.duplicate.createdAt : lhsKey < rhsKey
        }
    }

    /// What merging `duplicate` into `survivor` changed — enough for the
    /// caller (`ShareTripView`) to enqueue the exact same op shapes the
    /// app's existing paths already use for each table (no new server call
    /// shape): a `.itemAssignees` delete for every item the duplicate was
    /// assigned to, a `.itemAssignees` upsert for the subset that need a
    /// fresh survivor pairing, a `.packingItems` upsert per repointed row,
    /// and one `.tripProfiles` delete for `duplicate` itself.
    struct MergeResult {
        /// Items to `enqueueDeleteItemAssignee(itemId:, profileId:
        /// duplicate, ...)` for — every item the duplicate profile was
        /// assigned to, regardless of which branch below it fell into.
        var itemIdsToUnassignFromDuplicate: [UUID]
        /// The subset of the above that also need a fresh
        /// `enqueueUpsert(.itemAssignees, ...)` against `survivor` — excludes
        /// items the survivor was ALREADY assigned to (nothing new to write
        /// there; re-inserting would collide with `ItemAssignee`'s
        /// deterministic composite id).
        var itemIdsToAssignToSurvivor: [UUID]
        /// Packing rows whose `assigneeProfileId` moved to `survivor` —
        /// caller enqueues a plain `.packingItems` upsert per row.
        var repointedPackingItems: [PackingItem]
    }

    /// `nil` only on a genuine failure (the duplicate profile no longer
    /// exists locally, or the save itself threw) — caller surfaces that as
    /// a failure toast, same convention as `TripMerge.execute`/
    /// `HomeDuplication.cloneContent`.
    @MainActor
    static func merge(
        survivorId: UUID,
        duplicateId: UUID,
        tripId: UUID,
        modelContext: ModelContext,
        ensureTripLoaded: () async -> Void
    ) async -> MergeResult? {
        // `item_assignees` (like itinerary items/packing) enters the local
        // mirror only via `pullTrip` — same trip-scoped-mirror rule
        // `TripMerge`/`HomeDuplication` already document.
        await ensureTripLoaded()

        guard let duplicateProfile = (try? modelContext.fetch(FetchDescriptor<TripProfile>(
            predicate: #Predicate<TripProfile> { $0.id == duplicateId }
        )))?.first else { return nil }

        let oldAssignees = (try? modelContext.fetch(FetchDescriptor<ItemAssignee>(
            predicate: #Predicate<ItemAssignee> { $0.profileId == duplicateId }
        ))) ?? []
        let packingItems = (try? modelContext.fetch(FetchDescriptor<PackingItem>(
            predicate: #Predicate<PackingItem> { $0.tripId == tripId && $0.assigneeProfileId == duplicateId }
        ))) ?? []

        var unassignedFromDuplicate: [UUID] = []
        var assignedToSurvivor: [UUID] = []
        for old in oldAssignees {
            let itemId = old.itemId
            let survivorAlreadyAssignedCount = (try? modelContext.fetchCount(FetchDescriptor<ItemAssignee>(
                predicate: #Predicate<ItemAssignee> { $0.itemId == itemId && $0.profileId == survivorId }
            ))) ?? 0
            modelContext.delete(old)
            unassignedFromDuplicate.append(itemId)
            // A collision here (the item is ALREADY assigned to the
            // survivor too) must skip the insert — `ItemAssignee.id` is a
            // deterministic composite of (itemId, profileId), so inserting
            // a second row for the same pair would violate its own
            // `@Attribute(.unique)` at save time.
            if survivorAlreadyAssignedCount == 0 {
                modelContext.insert(ItemAssignee(itemId: itemId, profileId: survivorId))
                assignedToSurvivor.append(itemId)
            }
        }

        for packingItem in packingItems {
            packingItem.assigneeProfileId = survivorId
        }

        modelContext.delete(duplicateProfile)

        do {
            try modelContext.save()
        } catch {
            return nil
        }

        return MergeResult(
            itemIdsToUnassignFromDuplicate: unassignedFromDuplicate,
            itemIdsToAssignToSurvivor: assignedToSurvivor,
            repointedPackingItems: packingItems
        )
    }
}
