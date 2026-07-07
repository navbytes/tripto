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
