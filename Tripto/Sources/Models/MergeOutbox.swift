import Foundation

/// One outbox op a merge/dedupe flow would enqueue — same fields
/// `SyncStore.enqueueUpsert`/`enqueueDelete` take, computed ahead of time
/// instead of read back from the store afterward.
struct MergeOutboxOp: Equatable {
    var table: SyncTable
    var op: OutboxOpKind
    var rowId: UUID
    var tripId: UUID?
    var payloadJSON: String
}

/// D5 (reviewer, MED): `HomeView.performMerge`/`ShareTripView
/// .mergeDuplicateProfiles` each enqueue an ordered list of outbox ops
/// inline after their SwiftData merge call (`TripMerge.execute`/
/// `ProfileDedupe.merge`) — ordering matters (a delete-before-repoint would
/// race a server-side `ON DELETE CASCADE` ahead of the row it's meant to
/// move off first) but nothing returned that list for a test to inspect
/// without re-typing the view's own loop. These two pure functions compute
/// the exact ordered list each view enqueues, so a test — or, in a later
/// wave, the view itself — can call one function and assert/act on its
/// output rather than re-implementing the loop.
enum MergeOutbox {
    /// Mirrors `HomeView.performMerge`'s own enqueue loop, in order: one
    /// upsert per row `TripMerge.execute` already moved (its `tripId` is
    /// re-pointed to `survivorId` before `moved` is even returned), then the
    /// shell trip's own `.trips` delete — `performMerge`'s call into the
    /// view's existing `delete(_:)`, unchanged by this merge feature.
    static func performMergeOps(_ moved: TripMerge.Moved, shellId: UUID, survivorId: UUID) -> [MergeOutboxOp] {
        var ops: [MergeOutboxOp] = []
        for item in moved.items {
            ops.append(MergeOutboxOp(
                table: .itineraryItems, op: .upsert, rowId: item.id, tripId: survivorId, payloadJSON: encoded(item.toDTO())
            ))
        }
        for packingItem in moved.packing {
            ops.append(MergeOutboxOp(
                table: .packingItems, op: .upsert, rowId: packingItem.id, tripId: survivorId, payloadJSON: encoded(packingItem.toDTO())
            ))
        }
        for profile in moved.profiles {
            ops.append(MergeOutboxOp(
                table: .tripProfiles, op: .upsert, rowId: profile.id, tripId: survivorId, payloadJSON: encoded(profile.toDTO())
            ))
        }
        ops.append(MergeOutboxOp(table: .trips, op: .delete, rowId: shellId, tripId: shellId, payloadJSON: ""))
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
            ops.append(MergeOutboxOp(
                table: .itemAssignees, op: .delete,
                rowId: ItemAssignee.compositeId(itemId: itemId, profileId: duplicateId), tripId: tripId,
                payloadJSON: encoded(ItemAssigneeDTO(itemId: itemId, profileId: duplicateId))
            ))
        }
        for itemId in result.itemIdsToAssignToSurvivor {
            ops.append(MergeOutboxOp(
                table: .itemAssignees, op: .upsert,
                rowId: ItemAssignee.compositeId(itemId: itemId, profileId: survivorId), tripId: tripId,
                payloadJSON: encoded(ItemAssigneeDTO(itemId: itemId, profileId: survivorId))
            ))
        }
        for packingItem in result.repointedPackingItems {
            ops.append(MergeOutboxOp(
                table: .packingItems, op: .upsert, rowId: packingItem.id, tripId: tripId, payloadJSON: encoded(packingItem.toDTO())
            ))
        }
        ops.append(MergeOutboxOp(table: .tripProfiles, op: .delete, rowId: duplicateId, tripId: tripId, payloadJSON: ""))
        return ops
    }

    /// Same `JSONCoding.encoder` every real `SyncEngine.enqueueUpsert`/
    /// `enqueueDeleteItemAssignee` call encodes its payload with.
    private static func encoded(_ value: some Encodable) -> String {
        guard let data = try? JSONCoding.encoder.encode(value) else { return "{}" }
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
