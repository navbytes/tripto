import SwiftData
import XCTest
@testable import Tripto

/// SYNC_DESIGN.md "Local store" coalescing rules: one pending upsert per
/// `rowId` (a newer edit replaces it in place); a delete supersedes any
/// pending upsert for that row.
final class OutboxCoalescingTests: XCTestCase {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: AppSchema.makeContainer(inMemory: true))
    }

    func testUpsertThenUpsertCoalescesIntoOnePendingOp() async throws {
        let store = makeStore()
        let rowId = UUID()

        try await store.enqueueUpsert(
            table: .trips, rowId: rowId, tripId: rowId, payloadJSON: #"{"title":"First"}"#
        )
        try await store.enqueueUpsert(
            table: .trips, rowId: rowId, tripId: rowId, payloadJSON: #"{"title":"Second"}"#
        )

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1, "a second upsert on the same row must coalesce, not queue a new op")
        XCTAssertEqual(ops.first?.op, .upsert)
        XCTAssertEqual(ops.first?.payloadJSON, #"{"title":"Second"}"#, "the newer payload replaces the older one")
    }

    func testUpsertThenDeleteSupersedesToADelete() async throws {
        let store = makeStore()
        let rowId = UUID()

        try await store.enqueueUpsert(table: .trips, rowId: rowId, tripId: rowId, payloadJSON: "{}")
        try await store.enqueueDelete(table: .trips, rowId: rowId, tripId: rowId)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1, "a delete must replace the pending upsert, not queue alongside it")
        XCTAssertEqual(ops.first?.op, .delete)
    }

    func testDeleteThenUpsertReplacesBackToAnUpsert() async throws {
        // Not one of the two named cases, but the general "one pending op
        // per rowId" rule should hold symmetrically.
        let store = makeStore()
        let rowId = UUID()

        try await store.enqueueDelete(table: .trips, rowId: rowId, tripId: rowId)
        try await store.enqueueUpsert(table: .trips, rowId: rowId, tripId: rowId, payloadJSON: "{}")

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.op, .upsert)
    }

    /// P6.2 `TripMerge`/`HomeView.performMerge`: the shell trip's own item
    /// can already have a pending (unpushed) upsert when a merge starts —
    /// e.g. an offline edit queued before the duplicate pair was ever
    /// detected. The merge's own re-upsert for that SAME row (re-pointing
    /// `tripId` to the survivor) must coalesce into the pre-existing op, not
    /// queue a second one; the shell trip's OWN `trips`-row delete (a
    /// different `rowId` entirely) must still land strictly after it in
    /// FIFO order — otherwise a server-side `ON DELETE CASCADE` from the
    /// shell trip could race ahead of the re-point that's meant to move this
    /// item off it first. Enqueued in the same order `TripMerge.execute` +
    /// `HomeView.performMerge`/`delete(_:)` actually issue them: item
    /// re-point, then shell delete.
    func testShellTripsPendingItemEditCoalescesWithAMergeAndOrdersBeforeTheShellDelete() async throws {
        let store = makeStore()
        let shellId = UUID()
        let survivorId = UUID()
        let itemId = UUID()

        // Pending BEFORE the merge starts (e.g. a title edit made offline).
        try await store.enqueueUpsert(table: .itineraryItems, rowId: itemId, tripId: shellId, payloadJSON: "PRE-MERGE-EDIT")

        // The merge itself: re-point the item, then delete the shell.
        try await store.enqueueUpsert(table: .itineraryItems, rowId: itemId, tripId: survivorId, payloadJSON: "REPOINTED-TO-SURVIVOR")
        try await store.enqueueDelete(table: .trips, rowId: shellId, tripId: shellId)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 2, "the item's pre-existing pending edit coalesces with the merge's re-point — one op, not two")
        XCTAssertEqual(ops[0].rowId, itemId)
        XCTAssertEqual(ops[0].op, .upsert)
        XCTAssertEqual(ops[0].tripId, survivorId, "the coalesced op carries the merge's fresh tripId, not the stale pre-merge one")
        XCTAssertEqual(ops[0].payloadJSON, "REPOINTED-TO-SURVIVOR")
        XCTAssertEqual(ops[1].rowId, shellId)
        XCTAssertEqual(ops[1].op, .delete, "the shell trip's own delete — a distinct rowId, so it queues alongside rather than colliding")
    }

    /// D5 (reviewer, MED — zero coverage on the outbox glue): the exact op
    /// SET `HomeView.performMerge` (+ its call to the existing `delete(_:)`)
    /// enqueues for a real merge — one upsert per moved item/packing/profile
    /// row, re-pointed to the SURVIVOR's `tripId`, then the shell's own
    /// `.trips` delete. `Moved` comes from a REAL `TripMerge.execute` call
    /// (not hand-typed), so this can't drift from what the SwiftData half
    /// actually produces; the enqueue calls themselves mirror
    /// `performMerge`'s own code, in order — same "SyncStore-level, no
    /// SyncEngine/network" shape as every other test in this file.
    @MainActor
    func testPerformMergeOpShapeIsOneUpsertPerMovedRowThenTheShellDelete() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let store = SyncStore(modelContainer: container)
        let shellId = UUID()
        let survivorId = UUID()

        let item = TestFixtures.makeItineraryItem(tripId: shellId, startsAt: .now)
        let packing = PackingItem(
            id: UUID(), tripId: shellId, label: "Sunscreen", groupKeyRaw: PackingGroupKey.shared.rawValue,
            assigneeProfileId: nil, isDone: false, createdBy: nil, createdAt: .now, updatedAt: .now, updatedBy: nil
        )
        let profile = TripProfile(id: UUID(), tripId: shellId, displayName: "Grandma", avatarColor: "sky", linkedUserId: nil, createdAt: .now)
        context.insert(item)
        context.insert(packing)
        context.insert(profile)
        try context.save()

        let mergeOutcome = await TripMerge.execute(
            shellTripId: shellId, survivorTripId: survivorId, modelContext: context, ensureBothLoaded: {}
        )
        let moved = try XCTUnwrap(mergeOutcome)

        // Mirrors `HomeView.performMerge`'s own enqueue loop, in order.
        for movedItem in moved.items {
            try await store.enqueueUpsert(table: .itineraryItems, rowId: movedItem.id, tripId: survivorId, payloadJSON: "{}")
        }
        for movedPacking in moved.packing {
            try await store.enqueueUpsert(table: .packingItems, rowId: movedPacking.id, tripId: survivorId, payloadJSON: "{}")
        }
        for movedProfile in moved.profiles {
            try await store.enqueueUpsert(table: .tripProfiles, rowId: movedProfile.id, tripId: survivorId, payloadJSON: "{}")
        }
        // The shell trip's own delete — `HomeView.delete(_:)`'s existing,
        // unchanged enqueue call.
        try await store.enqueueDelete(table: .trips, rowId: shellId, tripId: shellId)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 4, "one upsert per moved row, plus the shell's own trips delete")
        XCTAssertEqual(Set(ops.map(\.table)), [.itineraryItems, .packingItems, .tripProfiles, .trips])
        XCTAssertEqual(ops.filter { $0.op == .upsert }.count, 3)
        let tripsDelete = try XCTUnwrap(ops.first { $0.table == .trips })
        XCTAssertEqual(tripsDelete.op, .delete)
        XCTAssertEqual(tripsDelete.rowId, shellId)
        // Every moved row's upsert carries the SURVIVOR's tripId, not the
        // shell's — the whole point of a merge.
        XCTAssertTrue(ops.filter { $0.table != .trips }.allSatisfy { $0.tripId == survivorId })
    }

    /// D5: the exact op set `ShareTripView.mergeDuplicateProfiles` enqueues
    /// — a composite-key `.itemAssignees` delete per item unassigned from
    /// the duplicate, an `.itemAssignees` upsert per item that needed a
    /// fresh survivor pairing, a `.packingItems` upsert per repointed row,
    /// and one final `.tripProfiles` delete for the duplicate profile
    /// itself. `MergeResult` comes from a REAL `ProfileDedupe.merge` call.
    @MainActor
    func testMergeDuplicateProfilesOpShapeIsAssigneeAndPackingOpsThenTheProfileDelete() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let store = SyncStore(modelContainer: container)
        let tripId = UUID()
        let survivor = TripProfile(id: UUID(), tripId: tripId, displayName: "Mom", avatarColor: "amber", linkedUserId: nil, createdAt: .now)
        let duplicate = TripProfile(id: UUID(), tripId: tripId, displayName: "Mom", avatarColor: "moss", linkedUserId: nil, createdAt: .now)
        context.insert(survivor)
        context.insert(duplicate)
        let itemId = UUID()
        context.insert(ItemAssignee(itemId: itemId, profileId: duplicate.id))
        try context.save()

        let mergeOutcome = await ProfileDedupe.merge(
            survivorId: survivor.id, duplicateId: duplicate.id, tripId: tripId, modelContext: context, ensureTripLoaded: {}
        )
        let result = try XCTUnwrap(mergeOutcome)

        // Mirrors `ShareTripView.mergeDuplicateProfiles`'s own enqueue loop,
        // in order — the `.itemAssignees` delete's payload matches what
        // `enqueueDeleteItemAssignee` actually encodes (`ItemAssigneeSyncTests`'
        // own convention for this one composite-key table).
        for unassignedItemId in result.itemIdsToUnassignFromDuplicate {
            let dto = ItemAssigneeDTO(itemId: unassignedItemId, profileId: duplicate.id)
            let json = String(data: try JSONCoding.encoder.encode(dto), encoding: .utf8)!
            try await store.enqueueDelete(
                table: .itemAssignees, rowId: ItemAssignee.compositeId(itemId: unassignedItemId, profileId: duplicate.id),
                tripId: tripId, payloadJSON: json
            )
        }
        for assignedItemId in result.itemIdsToAssignToSurvivor {
            try await store.enqueueUpsert(
                table: .itemAssignees, rowId: ItemAssignee.compositeId(itemId: assignedItemId, profileId: survivor.id),
                tripId: tripId, payloadJSON: "{}"
            )
        }
        for packingItem in result.repointedPackingItems {
            try await store.enqueueUpsert(table: .packingItems, rowId: packingItem.id, tripId: tripId, payloadJSON: "{}")
        }
        try await store.enqueueDelete(table: .tripProfiles, rowId: duplicate.id, tripId: tripId)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 3, "one assignee delete, one assignee upsert (repointed), one profile delete")
        XCTAssertEqual(ops.filter { $0.table == .itemAssignees && $0.op == .delete }.count, 1)
        XCTAssertEqual(ops.filter { $0.table == .itemAssignees && $0.op == .upsert }.count, 1)
        let profileDelete = try XCTUnwrap(ops.first { $0.table == .tripProfiles })
        XCTAssertEqual(profileDelete.op, .delete)
        XCTAssertEqual(profileDelete.rowId, duplicate.id)
    }

    func testDistinctRowsQueueSeparateOps() async throws {
        let store = makeStore()
        try await store.enqueueUpsert(table: .trips, rowId: UUID(), tripId: nil, payloadJSON: "{}")
        try await store.enqueueUpsert(table: .trips, rowId: UUID(), tripId: nil, payloadJSON: "{}")

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 2)
    }

    func testANewEditResetsTheRetryBudget() async throws {
        let store = makeStore()
        let rowId = UUID()
        try await store.enqueueUpsert(table: .trips, rowId: rowId, tripId: rowId, payloadJSON: "{}")

        guard let opId = try await store.pendingOps().first?.id else {
            return XCTFail("expected a pending op")
        }
        try await store.markTransientFailure(opId: opId, error: "boom")
        try await store.enqueueUpsert(table: .trips, rowId: rowId, tripId: rowId, payloadJSON: #"{"v":2}"#)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.attempts, 0, "a fresh edit shouldn't inherit a prior failure's attempt count")
    }
}
