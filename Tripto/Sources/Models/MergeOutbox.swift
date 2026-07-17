import Foundation

/// One outbox op a merge/dedupe flow enqueues — same table/rowId/payload
/// shape `SyncStore.enqueueUpsert`/`enqueueDelete`/`SyncEngine
/// .enqueueDeleteItemAssignee` already take, just computed as data ahead of
/// the enqueue call instead of interleaved with it.
///
/// F3 (reviewer, LOW-MED): typed per table/op (not a generic `(table, op,
/// rowId, tripId, payloadJSON)` tuple), so the consuming view enqueues each
/// case's own DTO directly — no JSON encode-then-decode round trip back to a
/// string, and no `try?`/`"{}"` fallback silently dropping an op the
/// producer just built in memory. `rowId`/`tripId` for the three plain
/// upserts live on the DTO itself (every DTO already carries both); the
/// `.itemAssignees` cases still take `tripId` alongside since
/// `ItemAssigneeDTO` has none of its own (composite-keyed, trip-less table —
/// see that type's doc comment).
enum MergeOutboxOp: Equatable {
    case upsertItineraryItem(ItineraryItemDTO)
    case upsertPackingItem(PackingItemDTO)
    case upsertTripProfile(TripProfileDTO)
    case unassignItemAssignee(ItemAssigneeDTO, tripId: UUID)
    case assignItemAssignee(ItemAssigneeDTO, tripId: UUID)
    case deleteTripProfile(id: UUID, tripId: UUID)
    case deleteTrip(id: UUID)
}

/// D5 (reviewer, MED): `HomeView.performMerge`/`ShareTripView
/// .mergeDuplicateProfiles` each enqueue an ordered list of outbox ops
/// inline after their SwiftData merge call (`TripMerge.execute`/
/// `ProfileDedupe.merge`) — ordering matters (a delete-before-repoint would
/// race a server-side `ON DELETE CASCADE` ahead of the row it's meant to
/// move off first) but nothing returned that list for a test to inspect
/// without re-typing the view's own loop. These two pure functions compute
/// the exact ordered list each view enqueues, so a test — or the view
/// itself — can call one function and assert/act on its output rather than
/// re-implementing the loop.
enum MergeOutbox {
    /// Mirrors `HomeView.performMerge`'s own enqueue loop, in order: one
    /// upsert per row `TripMerge.execute` already moved (its `tripId` is
    /// re-pointed to `survivorId` before `moved` is even returned), then the
    /// shell trip's own `.trips` delete LAST.
    ///
    /// F1 (reviewer, MED): that trailing delete must be enqueued from the
    /// SAME sequential loop that replays the upserts above it — `performMerge`
    /// folds it into one `for op in ops` loop rather than a second `Task`
    /// (the old `delete(_:)` call), which could otherwise race `SyncStore`'s
    /// arrival-order `seq` assignment ahead of an unfinished repoint.
    static func performMergeOps(_ moved: TripMerge.Moved, shellId: UUID, survivorId: UUID) -> [MergeOutboxOp] {
        var ops: [MergeOutboxOp] = []
        for item in moved.items {
            ops.append(.upsertItineraryItem(item.toDTO()))
        }
        for packingItem in moved.packing {
            ops.append(.upsertPackingItem(packingItem.toDTO()))
        }
        for profile in moved.profiles {
            ops.append(.upsertTripProfile(profile.toDTO()))
        }
        ops.append(.deleteTrip(id: shellId))
        return ops
    }

    /// Mirrors `ShareTripView.mergeDuplicateProfiles`'s own enqueue loop, in
    /// order: an `.itemAssignees` delete per item unassigned from the
    /// duplicate (`SyncEngine.enqueueDeleteItemAssignee`'s own payload
    /// shape — the duplicate's own id, not the survivor's), an
    /// `.itemAssignees` upsert per item re-paired to the survivor, a
    /// `.packingItems` upsert per repointed row, then the duplicate
    /// profile's own `.tripProfiles` delete.
    static func mergeDuplicateProfilesOps(
        _ result: ProfileDedupe.MergeResult, survivorId: UUID, duplicateId: UUID, tripId: UUID
    ) -> [MergeOutboxOp] {
        var ops: [MergeOutboxOp] = []
        for itemId in result.itemIdsToUnassignFromDuplicate {
            ops.append(.unassignItemAssignee(ItemAssigneeDTO(itemId: itemId, profileId: duplicateId), tripId: tripId))
        }
        for itemId in result.itemIdsToAssignToSurvivor {
            ops.append(.assignItemAssignee(ItemAssigneeDTO(itemId: itemId, profileId: survivorId), tripId: tripId))
        }
        for packingItem in result.repointedPackingItems {
            ops.append(.upsertPackingItem(packingItem.toDTO()))
        }
        ops.append(.deleteTripProfile(id: duplicateId, tripId: tripId))
        return ops
    }
}
