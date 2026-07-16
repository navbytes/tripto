import SwiftData
import XCTest
@testable import Tripto

/// E2's review: `flushPush()`'s FIFO loop used to push every queued op
/// regardless of how the previous one failed. If the *first* op in a
/// parent-then-children enqueue (e.g. `duplicateContent`'s trip, then its
/// cloned items/packing) failed TRANSIENTLY, its children were still pushed
/// against a trip that doesn't exist server-side yet, classified PERMANENT
/// (FK/RLS), and dropped for good — even though the trip itself went on to
/// succeed on a later retry. Fix (`SyncEngine+Push.swift`'s `flushPush()`):
/// a transient head failure halts the pass; a permanent one does not.
///
/// These exercise the real `flushPush()` loop end to end — not just
/// `PushErrorClassifier`, which `PushErrorClassifierTests.swift` already
/// covers in isolation — while staying hermetic: every op here carries a
/// `payloadJSON` that isn't valid JSON, so `pushUpsert` throws inside
/// `JSONCoding.passthroughDecoder.decode` *before* it ever reaches
/// `Supa.client` — a real, deterministic failure with zero network calls.
/// Whether that failure classifies transient or permanent is controlled the
/// same way the retry budget itself is: pre-spending `attempts` via
/// `markTransientFailure` (the same call `handlePushFailure` makes) up to
/// one short of `SyncEngine.maxPushAttempts` forces the next failure to read
/// as budget-exhausted-permanent (`PushErrorClassifier.classify`'s own
/// rule) — same shape as an RLS/constraint rejection for this loop's
/// purposes, only reachable here without fabricating a live `PostgrestError`.
///
/// One side effect of going through the real actor: a transient failure's
/// `scheduleRetry` still spawns its own untracked background `Task`, same
/// as in production. It fires on its own backoff schedule after the test
/// method has already returned, retries against the same unpushable
/// payload, and eventually resolves itself (permanent, once its own budget
/// is spent) — harmless (own container, no shared state, never touches the
/// network), just not instantly torn down. Not worth restructuring
/// `scheduleRetry` to avoid.
final class SyncEnginePushLoopTests: XCTestCase {
    /// `forcedOnline: true` — a test-only mirror of the `-simulateOffline`
    /// seam (`SyncEngine`'s own doc comment) — so these run deterministically
    /// regardless of the test host's real network/`NWPathMonitor` timing,
    /// rather than skipping when that raced offline.
    private func makeEngine() async throws -> (engine: SyncEngine, store: SyncStore) {
        let container = AppSchema.makeContainer(inMemory: true)
        let engine = SyncEngine(modelContainer: container, status: await SyncStatus(), forcedOnline: true)
        return (engine, SyncStore(modelContainer: container))
    }

    /// Three ops, oldest-first, each with a `payloadJSON` that fails to
    /// decode as JSON — see the file doc comment for why that's a
    /// deterministic, network-free push failure. FIFO order comes from
    /// `OutboxOp.seq` (assigned in enqueue order), not wall-clock timing, so
    /// no inter-enqueue delay is needed to keep it deterministic.
    private func enqueueThreeUnpushableOps(_ store: SyncStore) async throws -> (a: UUID, b: UUID, c: UUID) {
        let a = UUID(), b = UUID(), c = UUID()
        for rowId in [a, b, c] {
            try await store.enqueueUpsert(table: .trips, rowId: rowId, tripId: rowId, payloadJSON: "not valid json")
        }
        return (a, b, c)
    }

    /// Burns `rowId`'s op down to one attempt short of the cap so its next
    /// failure reads as budget-exhausted-PERMANENT rather than transient.
    private func exhaustRetryBudget(for rowId: UUID, store: SyncStore) async throws {
        let opId = try await store.pendingOps().first { $0.rowId == rowId }!.id
        for _ in 0..<(SyncEngine.maxPushAttempts - 1) {
            try await store.markTransientFailure(opId: opId, error: "seeding retry budget for test")
        }
    }

    // MARK: - 1. Transient head failure halts the pass

    func testTransientHeadFailureHaltsThePassLeavingLaterOpsUntouched() async throws {
        let (engine, store) = try await makeEngine()
        let (aId, bId, cId) = try await enqueueThreeUnpushableOps(store)

        await engine.flushPush()

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.map(\.rowId), [aId, bId, cId], "nothing dropped, FIFO order preserved")
        XCTAssertEqual(ops.first { $0.rowId == aId }?.attempts, 1, "the head was attempted, its budget spent by one")
        XCTAssertEqual(ops.first { $0.rowId == bId }?.attempts, 0, "a transient head failure must halt the pass")
        XCTAssertEqual(ops.first { $0.rowId == cId }?.attempts, 0, "never reached — still behind the halted head")
    }

    // MARK: - 2. The next pass re-drains FIFO once the head clears

    func testHeadClearingUnblocksExactlyTheNextOpInFIFOOrder() async throws {
        let (engine, store) = try await makeEngine()
        let (aId, bId, cId) = try await enqueueThreeUnpushableOps(store)

        await engine.flushPush() // pass 1: A fails transient, halts before B/C

        // Simulate A's retry succeeding server-side — `markPushed` is the
        // exact call `push(_:)` itself makes on success (SyncEngine+Push.swift),
        // the least-fake stand-in for "the real network call would have
        // taken this same path."
        let opAId = try await store.pendingOps().first { $0.rowId == aId }!.id
        try await store.markPushed(opId: opAId)

        await engine.flushPush() // pass 2: B is now the head

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.map(\.rowId), [bId, cId], "A cleared; B and C remain, in order")
        XCTAssertEqual(ops.first { $0.rowId == bId }?.attempts, 1, "B — now the head — was attempted on the next pass")
        XCTAssertEqual(ops.first { $0.rowId == cId }?.attempts, 0, "B's own transient failure halts pass 2 before C")
    }

    // MARK: - 3. A permanent failure does not halt the pass

    func testPermanentFailureDoesNotHaltThePass() async throws {
        let (engine, store) = try await makeEngine()
        let (aId, bId, cId) = try await enqueueThreeUnpushableOps(store)
        // All three read as budget-exhausted-PERMANENT this pass, isolating
        // "continue past a permanent drop" from the "halt on transient"
        // behavior test 1 already covers.
        for rowId in [aId, bId, cId] {
            try await exhaustRetryBudget(for: rowId, store: store)
        }

        await engine.flushPush()

        let ops = try await store.pendingOps()
        XCTAssertTrue(ops.isEmpty, "a permanent failure must not block the pass — every op here was reached and dropped")
        let issues = try await store.allIssues()
        XCTAssertEqual(Set(issues.map(\.rowId)), [aId, bId, cId], "each op's permanent failure is recorded, not silently lost")
    }
}
