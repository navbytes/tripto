import SwiftData
import XCTest
@testable import Tripto

/// M4: `ItemAssignee`'s composite-key (`item_id`, `profile_id`) local
/// identity and its outbox/pull-apply handling — the one new synced entity
/// this milestone adds. Same "SyncStore-level, no SyncEngine/network" shape
/// as `OutboxCoalescingTests`/`PullApplyReconcileTests` (this milestone's
/// brief §5: "item_assignees composite-key coalescing/delete").
final class ItemAssigneeSyncTests: XCTestCase {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: AppSchema.makeContainer(inMemory: true))
    }

    // MARK: - compositeId

    func testCompositeIdIsDeterministic() {
        let itemId = UUID()
        let profileId = UUID()
        XCTAssertEqual(
            ItemAssignee.compositeId(itemId: itemId, profileId: profileId),
            ItemAssignee.compositeId(itemId: itemId, profileId: profileId)
        )
    }

    func testCompositeIdDiffersForDifferentPairs() {
        let itemA = UUID()
        let itemB = UUID()
        let profile = UUID()
        XCTAssertNotEqual(
            ItemAssignee.compositeId(itemId: itemA, profileId: profile),
            ItemAssignee.compositeId(itemId: itemB, profileId: profile)
        )
    }

    /// Guards against a naive commutative mix (plain XOR) — see
    /// `ItemAssignee.compositeId`'s doc comment.
    func testCompositeIdIsNotCommutative() {
        let a = UUID()
        let b = UUID()
        XCTAssertNotEqual(
            ItemAssignee.compositeId(itemId: a, profileId: b),
            ItemAssignee.compositeId(itemId: b, profileId: a)
        )
    }

    // MARK: - Outbox coalescing

    func testAssignThenReassignCoalescesToOnePendingUpsert() async throws {
        let store = makeStore()
        let itemId = UUID()
        let profileId = UUID()
        let rowId = ItemAssignee.compositeId(itemId: itemId, profileId: profileId)
        let dto = ItemAssigneeDTO(itemId: itemId, profileId: profileId)
        let json = String(data: try JSONCoding.encoder.encode(dto), encoding: .utf8)!

        try await store.enqueueUpsert(table: .itemAssignees, rowId: rowId, tripId: nil, payloadJSON: json)
        try await store.enqueueUpsert(table: .itemAssignees, rowId: rowId, tripId: nil, payloadJSON: json)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1, "assigning the same pair twice must coalesce, not queue a second op")
        XCTAssertEqual(ops.first?.table, .itemAssignees)
    }

    /// The composite-key delete case this milestone specifically calls
    /// out: `SyncEngine.enqueueDeleteItemAssignee` carries the real
    /// item_id/profile_id pair through the outbox (unlike every other
    /// table's plain-`rowId` delete), since `SyncEngine+Push.pushDelete`'s
    /// `.itemAssignees` branch decodes it back out to build
    /// `.eq("item_id", ...).eq("profile_id", ...)`. Exercised here at the
    /// `SyncStore` level (constructing the same payload shape that method
    /// would) to stay hermetic/network-free.
    func testAssignThenUnassignSupersedesToADeleteCarryingBothColumns() async throws {
        let store = makeStore()
        let itemId = UUID()
        let profileId = UUID()
        let rowId = ItemAssignee.compositeId(itemId: itemId, profileId: profileId)
        let dto = ItemAssigneeDTO(itemId: itemId, profileId: profileId)
        let json = String(data: try JSONCoding.encoder.encode(dto), encoding: .utf8)!

        try await store.enqueueUpsert(table: .itemAssignees, rowId: rowId, tripId: nil, payloadJSON: json)
        try await store.enqueueDelete(table: .itemAssignees, rowId: rowId, tripId: nil, payloadJSON: json)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1, "unassigning must replace the pending upsert, not queue alongside it")
        XCTAssertEqual(ops.first?.op, .delete)

        let decoded = try JSONCoding.decoder.decode(ItemAssigneeDTO.self, from: Data(ops[0].payloadJSON.utf8))
        XCTAssertEqual(decoded.itemId, itemId)
        XCTAssertEqual(decoded.profileId, profileId)
    }

    func testDistinctPairsQueueSeparateOps() async throws {
        let store = makeStore()
        let itemId = UUID()
        try await store.enqueueUpsert(
            table: .itemAssignees, rowId: ItemAssignee.compositeId(itemId: itemId, profileId: UUID()),
            tripId: nil, payloadJSON: "{}"
        )
        try await store.enqueueUpsert(
            table: .itemAssignees, rowId: ItemAssignee.compositeId(itemId: itemId, profileId: UUID()),
            tripId: nil, payloadJSON: "{}"
        )
        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 2, "two different profiles assigned to the same item are two distinct rows")
    }

    // MARK: - Pull-apply (SyncStore.applyItemAssignees)

    func testApplyItemAssigneesUpsertsAndScopesDeletesToThisTripsItems() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let tripA = UUID()
        let tripB = UUID()
        let itemA = TestFixtures.makeItineraryItem(tripId: tripA, startsAt: .now)
        let itemB = TestFixtures.makeItineraryItem(tripId: tripB, startsAt: .now)
        context.insert(itemA)
        context.insert(itemB)
        try context.save()

        let profile1 = UUID()
        let profile2 = UUID()

        try await store.applyItemAssignees([ItemAssigneeDTO(itemId: itemA.id, profileId: profile1)], tripId: tripA)
        try await store.applyItemAssignees([ItemAssigneeDTO(itemId: itemB.id, profileId: profile2)], tripId: tripB)

        var allAssignees = try context.fetch(FetchDescriptor<ItemAssignee>())
        XCTAssertEqual(allAssignees.count, 2)

        // A second, now-empty pull for tripA only must delete tripA's row
        // but leave tripB's alone — `ItemAssignee` has no `tripId` of its
        // own, so this is exactly the cross-trip isolation the item-id-based
        // scoping (`SyncStore.applyItemAssignees`'s doc comment) has to get
        // right.
        try await store.applyItemAssignees([], tripId: tripA)

        allAssignees = try context.fetch(FetchDescriptor<ItemAssignee>())
        XCTAssertEqual(allAssignees.count, 1)
        XCTAssertEqual(allAssignees.first?.itemId, itemB.id, "tripB's assignee must survive a tripA-only pull")
    }

    func testApplyItemAssigneesUpsertsExistingRowInPlaceRatherThanDuplicating() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let tripId = UUID()
        let item = TestFixtures.makeItineraryItem(tripId: tripId, startsAt: .now)
        context.insert(item)
        try context.save()

        let profileId = UUID()
        try await store.applyItemAssignees([ItemAssigneeDTO(itemId: item.id, profileId: profileId)], tripId: tripId)
        try await store.applyItemAssignees([ItemAssigneeDTO(itemId: item.id, profileId: profileId)], tripId: tripId)

        let rows = try context.fetch(FetchDescriptor<ItemAssignee>())
        XCTAssertEqual(rows.count, 1, "re-pulling the same assignment must not duplicate the local row")
    }

    /// SYNC_DESIGN.md Principle 2: "a pull never clobbers rows with
    /// pending local ops."
    func testApplyItemAssigneesProtectsRowsWithPendingLocalOps() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let tripId = UUID()
        let item = TestFixtures.makeItineraryItem(tripId: tripId, startsAt: .now)
        context.insert(item)
        try context.save()

        let profileId = UUID()
        try await store.applyItemAssignees([ItemAssigneeDTO(itemId: item.id, profileId: profileId)], tripId: tripId)

        // Simulate an unpushed local unassign sitting in the outbox.
        let rowId = ItemAssignee.compositeId(itemId: item.id, profileId: profileId)
        try await store.enqueueDelete(table: .itemAssignees, rowId: rowId, tripId: tripId)

        // Server pull still reports it present (hasn't seen the delete
        // yet) — must not be re-upserted over the pending delete, and must
        // not be reconciled away either (it's not "absent," it's pending).
        try await store.applyItemAssignees([ItemAssigneeDTO(itemId: item.id, profileId: profileId)], tripId: tripId)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1, "the pending delete must survive the pull unclobbered")
        XCTAssertEqual(ops.first?.op, .delete)
    }

    func testPruneOrphansRemovesItemAssigneesWhoseTripDisappeared() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let keepTripId = UUID()
        let goneTripId = UUID()
        // Only the surviving trip has a local `Trip` row — mirrors a trip
        // that was deleted/membership-revoked elsewhere and already pruned.
        context.insert(Trip(dto: TestFixtures.makeTripDTO(id: keepTripId)))

        let keepItem = TestFixtures.makeItineraryItem(tripId: keepTripId, startsAt: .now)
        let goneItem = TestFixtures.makeItineraryItem(tripId: goneTripId, startsAt: .now)
        context.insert(keepItem)
        context.insert(goneItem)
        context.insert(ItemAssignee(itemId: keepItem.id, profileId: UUID()))
        context.insert(ItemAssignee(itemId: goneItem.id, profileId: UUID()))
        try context.save()

        try await store.pruneOrphans()

        let remaining = try context.fetch(FetchDescriptor<ItemAssignee>())
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.itemId, keepItem.id)
    }
}
