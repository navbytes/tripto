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
