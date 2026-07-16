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

    /// D5 (reviewer, MED — zero coverage on the outbox glue): the exact
    /// ordered op list `HomeView.performMerge` enqueues for a real merge —
    /// one upsert per moved item/packing/profile row, re-pointed to the
    /// SURVIVOR's `tripId`, then the shell's own `.trips` delete LAST (a
    /// server-side `ON DELETE CASCADE` racing ahead of the re-point above
    /// would orphan rows still mid-move). `moved` comes from a REAL
    /// `TripMerge.execute` call (not hand-typed); `MergeOutbox
    /// .performMergeOps` is the SAME producer `performMerge` itself would
    /// call, so this can no longer drift into re-implementing the view's own
    /// enqueue loop the way this test used to (reviewer finding).
    @MainActor
    func testPerformMergeOpShapeIsOneUpsertPerMovedRowThenTheShellDelete() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
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

        let ops = MergeOutbox.performMergeOps(moved, shellId: shellId, survivorId: survivorId)

        // F3 (reviewer, LOW-MED): `MergeOutboxOp` now carries each row's real
        // DTO directly, so comparing against `item.toDTO()`/`packing.toDTO()`/
        // `profile.toDTO()` needs no JSON round trip — these are the exact
        // same in-memory values `moved` carries (already re-pointed to
        // `survivorId` by `TripMerge.execute`), not a re-encoded copy.
        XCTAssertEqual(
            ops,
            [
                .upsertItineraryItem(item.toDTO()),
                .upsertPackingItem(packing.toDTO()),
                .upsertTripProfile(profile.toDTO()),
                .deleteTrip(id: shellId)
            ],
            "one upsert per moved row, re-pointed to the survivor, then the shell's own trips delete LAST"
        )
        // F1 (reviewer, MED): named out explicitly, on top of the full-array
        // check above — a single sequential enqueue loop over this list must
        // send the shell's own delete after every repoint, never before.
        XCTAssertEqual(ops.last, .deleteTrip(id: shellId), "the shell's own trips delete must be the trailing op")
    }

    /// D5: the exact ordered op list `ShareTripView.mergeDuplicateProfiles`
    /// enqueues — a composite-key `.itemAssignees` delete per item
    /// unassigned from the duplicate, an `.itemAssignees` upsert per item
    /// that needed a fresh survivor pairing, a `.packingItems` upsert per
    /// repointed row, and one final `.tripProfiles` delete for the duplicate
    /// profile itself. `result` comes from a REAL `ProfileDedupe.merge`
    /// call; `MergeOutbox.mergeDuplicateProfilesOps` is the SAME producer
    /// the view would call, so this asserts on its real output rather than
    /// re-implementing the enqueue loop (reviewer finding) — the fixture
    /// includes a repointed packing item too, closing a gap the old
    /// hand-rolled version of this test never actually exercised (its own
    /// doc comment claimed packing coverage with no packing fixture at all).
    @MainActor
    func testMergeDuplicateProfilesOpShapeIsAssigneeAndPackingOpsThenTheProfileDelete() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let tripId = UUID()
        let survivor = TripProfile(id: UUID(), tripId: tripId, displayName: "Mom", avatarColor: "amber", linkedUserId: nil, createdAt: .now)
        let duplicate = TripProfile(id: UUID(), tripId: tripId, displayName: "Mom", avatarColor: "moss", linkedUserId: nil, createdAt: .now)
        context.insert(survivor)
        context.insert(duplicate)
        let itemId = UUID()
        context.insert(ItemAssignee(itemId: itemId, profileId: duplicate.id))
        let packing = PackingItem(
            id: UUID(), tripId: tripId, label: "Sunscreen", groupKeyRaw: PackingGroupKey.shared.rawValue,
            assigneeProfileId: duplicate.id, isDone: false, createdBy: nil, createdAt: .now, updatedAt: .now, updatedBy: nil
        )
        context.insert(packing)
        try context.save()

        let mergeOutcome = await ProfileDedupe.merge(
            survivorId: survivor.id, duplicateId: duplicate.id, tripId: tripId, modelContext: context, ensureTripLoaded: {}
        )
        let result = try XCTUnwrap(mergeOutcome)

        let ops = MergeOutbox.mergeDuplicateProfilesOps(result, survivorId: survivor.id, duplicateId: duplicate.id, tripId: tripId)

        // See the previous test's comment for why comparing typed ops
        // against each row's own `toDTO()`/constructed DTO needs no JSON
        // round trip.
        XCTAssertEqual(
            ops,
            [
                .unassignItemAssignee(ItemAssigneeDTO(itemId: itemId, profileId: duplicate.id), tripId: tripId),
                .assignItemAssignee(ItemAssigneeDTO(itemId: itemId, profileId: survivor.id), tripId: tripId),
                .upsertPackingItem(packing.toDTO()),
                .deleteTripProfile(id: duplicate.id, tripId: tripId)
            ],
            "unassign from the duplicate, re-pair to the survivor, repoint packing, then the duplicate's own profile delete LAST"
        )
    }

    func testDistinctRowsQueueSeparateOps() async throws {
        let store = makeStore()
        try await store.enqueueUpsert(table: .trips, rowId: UUID(), tripId: nil, payloadJSON: "{}")
        try await store.enqueueUpsert(table: .trips, rowId: UUID(), tripId: nil, payloadJSON: "{}")

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 2)
    }

    /// F1/F2 (reviewer, MED): the merge path's whole ordering guarantee rests
    /// on `nextSeq()` handing out a strictly increasing value to each
    /// sequential enqueue — this is the direct proof, independent of any
    /// particular caller (merge, plain edits, whatever).
    func testSequentialEnqueuesYieldStrictlyIncreasingSeq() async throws {
        let store = makeStore()
        for _ in 0..<5 {
            try await store.enqueueUpsert(table: .trips, rowId: UUID(), tripId: nil, payloadJSON: "{}")
        }

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.map(\.seq), [0, 1, 2, 3, 4], "each sequential enqueue must get the next integer seq")
    }

    /// F2 (reviewer, MED): every `OutboxOp` row written before the `seq`
    /// column existed lightweight-migrates it to `0` (`OutboxOp.seq`'s own
    /// doc comment) — simulated directly here (bypassing `enqueueUpsert`,
    /// which always assigns a fresh nonzero `seq`) via raw rows sharing
    /// `seq: 0`, inserted newer-first on purpose to prove the recovered
    /// order comes from `createdAt`, not array/insertion order.
    func testPendingOpsBreaksSeqTiesByCreatedAtForPreMigrationRows() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)
        let olderId = UUID()
        let newerId = UUID()

        context.insert(OutboxOp(
            createdAt: Date(timeIntervalSince1970: 200), tableRaw: SyncTable.trips.rawValue,
            opRaw: OutboxOpKind.upsert.rawValue, rowId: newerId, tripId: newerId, payloadJSON: "{}", seq: 0
        ))
        context.insert(OutboxOp(
            createdAt: Date(timeIntervalSince1970: 100), tableRaw: SyncTable.trips.rawValue,
            opRaw: OutboxOpKind.upsert.rawValue, rowId: olderId, tripId: olderId, payloadJSON: "{}", seq: 0
        ))
        try context.save()

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.map(\.rowId), [olderId, newerId], "tied at seq 0 — createdAt recovers FIFO order")
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
