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

        XCTAssertEqual(ops.count, 4, "one upsert per moved row, plus the shell's own trips delete")
        // Exact shape AND order. Payloads are asserted by decoding back into
        // the DTO and comparing structs, not by comparing JSON strings
        // byte-for-byte (`JSONCoding.encoder` has no `.sortedKeys`, so two
        // independent `encode()` calls of the same value aren't guaranteed
        // identical key order) — and the *expected* side is round-tripped
        // through the same encoder/decoder too (`roundTripped` below),
        // since its ISO8601-with-fractional-seconds date strategy is only
        // millisecond-precision, coarser than `Date.now`'s own resolution;
        // comparing an un-round-tripped `Date` against a round-tripped one
        // would fail on that precision gap alone. `item.toDTO()`/
        // `packing.toDTO()`/`profile.toDTO()` read each row's state as
        // `TripMerge.execute` already left it (re-pointed to `survivorId`),
        // the same instances `moved` carries, so this also confirms the
        // producer encodes the row's real DTO rather than a stand-in payload.
        XCTAssertEqual(ops[0].table, .itineraryItems)
        XCTAssertEqual(ops[0].op, .upsert)
        XCTAssertEqual(ops[0].rowId, item.id)
        XCTAssertEqual(ops[0].tripId, survivorId)
        XCTAssertEqual(try decodedPayload(ops[0], as: ItineraryItemDTO.self), try roundTripped(item.toDTO()))

        XCTAssertEqual(ops[1].table, .packingItems)
        XCTAssertEqual(ops[1].op, .upsert)
        XCTAssertEqual(ops[1].rowId, packing.id)
        XCTAssertEqual(ops[1].tripId, survivorId)
        XCTAssertEqual(try decodedPayload(ops[1], as: PackingItemDTO.self), try roundTripped(packing.toDTO()))

        XCTAssertEqual(ops[2].table, .tripProfiles)
        XCTAssertEqual(ops[2].op, .upsert)
        XCTAssertEqual(ops[2].rowId, profile.id)
        XCTAssertEqual(ops[2].tripId, survivorId)
        XCTAssertEqual(try decodedPayload(ops[2], as: TripProfileDTO.self), try roundTripped(profile.toDTO()))

        XCTAssertEqual(
            ops[3],
            MergeOutboxOp(table: .trips, op: .delete, rowId: shellId, tripId: shellId, payloadJSON: ""),
            "the shell's own delete must be LAST, after every moved row's re-point"
        )
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

        // See the previous test's comment for why payloads are decoded and
        // compared as structs rather than as raw JSON strings.
        XCTAssertEqual(ops.count, 4, "one assignee delete, one assignee upsert (repointed), one packing upsert, one profile delete")

        XCTAssertEqual(ops[0].table, .itemAssignees)
        XCTAssertEqual(ops[0].op, .delete, "unassign from the duplicate first")
        XCTAssertEqual(ops[0].rowId, ItemAssignee.compositeId(itemId: itemId, profileId: duplicate.id))
        XCTAssertEqual(ops[0].tripId, tripId)
        XCTAssertEqual(try decodedPayload(ops[0], as: ItemAssigneeDTO.self), ItemAssigneeDTO(itemId: itemId, profileId: duplicate.id))

        XCTAssertEqual(ops[1].table, .itemAssignees)
        XCTAssertEqual(ops[1].op, .upsert, "then re-pair to the survivor")
        XCTAssertEqual(ops[1].rowId, ItemAssignee.compositeId(itemId: itemId, profileId: survivor.id))
        XCTAssertEqual(ops[1].tripId, tripId)
        XCTAssertEqual(try decodedPayload(ops[1], as: ItemAssigneeDTO.self), ItemAssigneeDTO(itemId: itemId, profileId: survivor.id))

        XCTAssertEqual(ops[2].table, .packingItems)
        XCTAssertEqual(ops[2].op, .upsert, "the repointed packing row")
        XCTAssertEqual(ops[2].rowId, packing.id)
        XCTAssertEqual(ops[2].tripId, tripId)
        XCTAssertEqual(try decodedPayload(ops[2], as: PackingItemDTO.self), try roundTripped(packing.toDTO()))

        XCTAssertEqual(
            ops[3],
            MergeOutboxOp(table: .tripProfiles, op: .delete, rowId: duplicate.id, tripId: tripId, payloadJSON: ""),
            "the duplicate profile's own delete is LAST"
        )
    }

    /// Shared by both merge-op-shape tests above — `JSONCoding.decoder`
    /// undoes `MergeOutbox`'s own `JSONCoding.encoder` (snake_case ->
    /// camelCase), so decoding back into the DTO and comparing structs is
    /// order-independent, unlike comparing the raw JSON strings.
    private func decodedPayload<T: Decodable>(_ op: MergeOutboxOp, as type: T.Type) throws -> T {
        try JSONCoding.decoder.decode(type, from: Data(op.payloadJSON.utf8))
    }

    /// Same encode-then-decode idiom `DTORoundTripTests` uses for its own
    /// fidelity checks — needed here because `JSONCoding.encoder`'s
    /// ISO8601-with-fractional-seconds date strategy is only millisecond-
    /// precision, coarser than `Date.now`'s actual resolution. Comparing an
    /// un-round-tripped expected DTO against one that came back through
    /// `decodedPayload` above would spuriously fail on that precision gap.
    private func roundTripped<T: Codable>(_ value: T) throws -> T {
        try JSONCoding.decoder.decode(T.self, from: JSONCoding.encoder.encode(value))
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
