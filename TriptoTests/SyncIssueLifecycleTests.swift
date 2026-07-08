import SwiftData
import XCTest
@testable import Tripto

/// FIX #1: a permanently-failed outbox op used to just vanish into a
/// `SyncIssue` row nothing ever read. This is the `SyncStore`-level half of
/// making that surfaceable/actionable — same "SyncStore-level, no
/// SyncEngine/network" shape as `OutboxCoalescingTests`/`ItemAssigneeSyncTests`
/// (`SyncEngine.dismissIssue`/`retryIssue`/`dismissAllIssues` themselves are
/// intentionally left untested here since they call `pullHome()`/network
/// paths this suite must stay hermetic against — see those methods' own
/// doc comments).
final class SyncIssueLifecycleTests: XCTestCase {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: AppSchema.makeContainer(inMemory: true))
    }

    // MARK: - markPermanentFailure -> allIssues()

    func testMarkPermanentFailureThreadsRetriableThroughToTheSnapshot() async throws {
        let store = makeStore()
        let rejectedRowId = UUID()
        let exhaustedRowId = UUID()

        try await store.enqueueUpsert(table: .trips, rowId: rejectedRowId, tripId: rejectedRowId, payloadJSON: "{}")
        let rejectedOpId = try await store.pendingOps().first { $0.rowId == rejectedRowId }!.id
        try await store.markPermanentFailure(
            opId: rejectedOpId, rowId: rejectedRowId, table: .trips, message: "RLS denied", retriable: false
        )

        try await store.enqueueUpsert(table: .itineraryItems, rowId: exhaustedRowId, tripId: nil, payloadJSON: "{}")
        let exhaustedOpId = try await store.pendingOps().first { $0.rowId == exhaustedRowId }!.id
        try await store.markPermanentFailure(
            opId: exhaustedOpId, rowId: exhaustedRowId, table: .itineraryItems, message: "gave up after 8 attempts", retriable: true
        )

        let issues = try await store.allIssues()
        XCTAssertEqual(issues.count, 2)

        let rejected = try XCTUnwrap(issues.first { $0.rowId == rejectedRowId })
        XCTAssertFalse(rejected.retriable, "an RLS-rejected write's issue must not be retriable")
        XCTAssertEqual(rejected.tableRaw, SyncTable.trips.rawValue)
        XCTAssertEqual(rejected.message, "RLS denied")

        let exhausted = try XCTUnwrap(issues.first { $0.rowId == exhaustedRowId })
        XCTAssertTrue(exhausted.retriable, "a budget-exhausted write's issue must be retriable")
    }

    func testMarkPermanentFailureDropsTheOutboxOp() async throws {
        let store = makeStore()
        let rowId = UUID()
        try await store.enqueueUpsert(table: .trips, rowId: rowId, tripId: rowId, payloadJSON: "{}")
        let opId = try await store.pendingOps().first!.id

        try await store.markPermanentFailure(opId: opId, rowId: rowId, table: .trips, message: "boom", retriable: false)

        let ops = try await store.pendingOps()
        XCTAssertTrue(ops.isEmpty, "a permanently-failed op must be dropped, never retried automatically")
    }

    func testAllIssuesIsSortedNewestFirst() async throws {
        let store = makeStore()
        let olderRowId = UUID()
        let newerRowId = UUID()

        try await store.enqueueUpsert(table: .trips, rowId: olderRowId, tripId: olderRowId, payloadJSON: "{}")
        let olderOpId = try await store.pendingOps().first!.id
        try await store.markPermanentFailure(opId: olderOpId, rowId: olderRowId, table: .trips, message: "older", retriable: false)

        try await Task.sleep(nanoseconds: 10_000_000) // ensure a distinct `at` timestamp

        try await store.enqueueUpsert(table: .trips, rowId: newerRowId, tripId: newerRowId, payloadJSON: "{}")
        let newerOpId = try await store.pendingOps().first!.id
        try await store.markPermanentFailure(opId: newerOpId, rowId: newerRowId, table: .trips, message: "newer", retriable: false)

        let issues = try await store.allIssues()
        XCTAssertEqual(issues.map(\.rowId), [newerRowId, olderRowId], "allIssues() must be newest-first")
    }

    // MARK: - dismissIssue / dismissAllIssues

    func testDismissIssueRemovesOnlyThatOne() async throws {
        let store = makeStore()
        let keepRowId = UUID()
        let dismissRowId = UUID()

        try await store.enqueueUpsert(table: .trips, rowId: keepRowId, tripId: keepRowId, payloadJSON: "{}")
        let keepOpId = try await store.pendingOps().first!.id
        try await store.markPermanentFailure(opId: keepOpId, rowId: keepRowId, table: .trips, message: "keep", retriable: false)

        try await store.enqueueUpsert(table: .trips, rowId: dismissRowId, tripId: dismissRowId, payloadJSON: "{}")
        let dismissOpId = try await store.pendingOps().first { $0.rowId == dismissRowId }!.id
        try await store.markPermanentFailure(opId: dismissOpId, rowId: dismissRowId, table: .trips, message: "dismiss me", retriable: false)

        let dismissIssueId = try await store.allIssues().first { $0.rowId == dismissRowId }!.id
        try await store.dismissIssue(id: dismissIssueId)

        let remaining = try await store.allIssues()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining.first?.rowId, keepRowId)
    }

    func testDismissAllIssuesClearsEverything() async throws {
        let store = makeStore()
        for _ in 0..<3 {
            let rowId = UUID()
            try await store.enqueueUpsert(table: .trips, rowId: rowId, tripId: rowId, payloadJSON: "{}")
            let opId = try await store.pendingOps().first { $0.rowId == rowId }!.id
            try await store.markPermanentFailure(opId: opId, rowId: rowId, table: .trips, message: "boom", retriable: false)
        }
        let issuesBeforeDismissAll = try await store.allIssues()
        XCTAssertEqual(issuesBeforeDismissAll.count, 3)

        try await store.dismissAllIssues()

        let issuesAfterDismissAll = try await store.allIssues()
        XCTAssertTrue(issuesAfterDismissAll.isEmpty)
    }

    // MARK: - reenqueueUpsertFromLocalRow ("Try again")

    func testReenqueueUpsertFromLocalRowRebuildsAnItineraryItemUpsert() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let tripId = UUID()
        let item = TestFixtures.makeItineraryItem(tripId: tripId, title: "Flight to Lisbon", startsAt: .now)
        context.insert(item)
        try context.save()

        let didRetry = try await store.reenqueueUpsertFromLocalRow(rowId: item.id, table: .itineraryItems)
        XCTAssertTrue(didRetry)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.op, .upsert)
        XCTAssertEqual(ops.first?.rowId, item.id)
        XCTAssertEqual(ops.first?.tripId, tripId)

        let decoded = try JSONCoding.decoder.decode(ItineraryItemDTO.self, from: Data(ops[0].payloadJSON.utf8))
        XCTAssertEqual(decoded.title, "Flight to Lisbon", "the re-enqueued payload must reflect the row's current local state")
    }

    func testReenqueueUpsertFromLocalRowRebuildsATripUpsert() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let tripId = UUID()
        let trip = Trip(dto: TestFixtures.makeTripDTO(id: tripId, title: "Lisbon Trip"))
        context.insert(trip)
        try context.save()

        let didRetry = try await store.reenqueueUpsertFromLocalRow(rowId: tripId, table: .trips)
        XCTAssertTrue(didRetry)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1)
        XCTAssertEqual(ops.first?.tripId, tripId, "a trip's own id is threaded through as its outbox op's tripId")
        let decoded = try JSONCoding.decoder.decode(TripDTO.self, from: Data(ops[0].payloadJSON.utf8))
        XCTAssertEqual(decoded.title, "Lisbon Trip")
    }

    func testReenqueueUpsertFromLocalRowRebuildsAPackingItemUpsert() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let tripId = UUID()
        let packingItem = PackingItem(
            id: UUID(), tripId: tripId, label: "Passport", groupKeyRaw: PackingGroupKey.documents.rawValue,
            assigneeProfileId: nil, isDone: false, createdBy: UUID(), createdAt: .now, updatedAt: .now, updatedBy: nil
        )
        context.insert(packingItem)
        try context.save()

        let didRetry = try await store.reenqueueUpsertFromLocalRow(rowId: packingItem.id, table: .packingItems)
        XCTAssertTrue(didRetry)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1)
        let decoded = try JSONCoding.decoder.decode(PackingItemDTO.self, from: Data(ops[0].payloadJSON.utf8))
        XCTAssertEqual(decoded.label, "Passport")
    }

    func testReenqueueUpsertFromLocalRowRebuildsATripProfileUpsert() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let tripId = UUID()
        let profile = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Meera", avatarColor: "coral", linkedUserId: nil, createdAt: .now
        )
        context.insert(profile)
        try context.save()

        let didRetry = try await store.reenqueueUpsertFromLocalRow(rowId: profile.id, table: .tripProfiles)
        XCTAssertTrue(didRetry)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1)
        let decoded = try JSONCoding.decoder.decode(TripProfileDTO.self, from: Data(ops[0].payloadJSON.utf8))
        XCTAssertEqual(decoded.displayName, "Meera")
    }

    func testReenqueueUpsertFromLocalRowIsANoOpForCompositeKeyTables() async throws {
        let store = makeStore()
        let didRetry = try await store.reenqueueUpsertFromLocalRow(rowId: UUID(), table: .itemAssignees)
        XCTAssertFalse(didRetry, "item_assignees has no single id to look a row up by, so there's nothing to retry")
        let ops = try await store.pendingOps()
        XCTAssertTrue(ops.isEmpty)
    }

    func testReenqueueUpsertFromLocalRowIsANoOpWhenTheRowNoLongerExistsLocally() async throws {
        let store = makeStore()
        let didRetry = try await store.reenqueueUpsertFromLocalRow(rowId: UUID(), table: .trips)
        XCTAssertFalse(didRetry, "a row that's since vanished locally has nothing left to re-send")
        let ops = try await store.pendingOps()
        XCTAssertTrue(ops.isEmpty)
    }
}
