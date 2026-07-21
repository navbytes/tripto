import SwiftData
import XCTest
@testable import Tripto

/// Release 1.2 (`.claude/company/release-1.2/PLAN.md` C1): `item_attachments`
/// outbox coalescing, pull-apply (upsert + delete-if-absent, pending
/// protection, `skippedCount` guard), `pruneOrphans`, and the prefetch
/// query — same `SyncStore`-level, no-`SyncEngine`/network shape as
/// `ItemAssigneeSyncTests`/`PullApplyReconcileTests` (SYNC_DESIGN.md "Apply
/// = upsert by id; then delete local rows absent from the server response
/// unless they have a pending outbox op").
final class ItemAttachmentSyncTests: XCTestCase {
    private func makeStore() -> SyncStore {
        SyncStore(modelContainer: AppSchema.makeContainer(inMemory: true))
    }

    // MARK: - Outbox coalescing

    func testUpsertThenUpsertCoalescesToOnePendingOp() async throws {
        let store = makeStore()
        let rowId = UUID()
        try await store.enqueueUpsert(table: .itemAttachments, rowId: rowId, tripId: UUID(), payloadJSON: "{}")
        try await store.enqueueUpsert(table: .itemAttachments, rowId: rowId, tripId: UUID(), payloadJSON: #"{"v":2}"#)

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1, "a second upsert on the same row must coalesce, not queue a new op")
        XCTAssertEqual(ops.first?.table, .itemAttachments)
        XCTAssertEqual(ops.first?.payloadJSON, #"{"v":2}"#)
    }

    func testDeleteSupersedesAPendingUpsert() async throws {
        let store = makeStore()
        let rowId = UUID()
        try await store.enqueueUpsert(table: .itemAttachments, rowId: rowId, tripId: UUID(), payloadJSON: "{}")
        try await store.enqueueDelete(table: .itemAttachments, rowId: rowId, tripId: UUID())

        let ops = try await store.pendingOps()
        XCTAssertEqual(ops.count, 1, "a delete must replace the pending upsert, not queue alongside it")
        XCTAssertEqual(ops.first?.op, .delete)
    }

    // MARK: - Pull-apply (SyncStore.applyItemAttachments)

    func testApplyUpsertsNewRowsAndUpdatesExistingOnesInPlace() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)
        let tripId = UUID()
        let id = UUID()

        try await store.applyItemAttachments(
            [TestFixtures.makeItemAttachmentDTO(id: id, tripId: tripId, fileName: "original.pdf")], tripId: tripId
        )
        try await store.applyItemAttachments(
            [TestFixtures.makeItemAttachmentDTO(id: id, tripId: tripId, fileName: "renamed.pdf")], tripId: tripId
        )

        let rows = try context.fetch(FetchDescriptor<ItemAttachment>())
        XCTAssertEqual(rows.count, 1, "an upsert-by-id must update in place, never duplicate")
        XCTAssertEqual(rows.first?.fileName, "renamed.pdf")
    }

    func testApplyDeletesAbsentRowsButProtectsPendingOnesAndScopesToTrip() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let tripA = UUID()
        let tripB = UUID()
        let keepId = UUID()
        let goneId = UUID()
        let pendingId = UUID()
        let otherTripId = UUID()

        try await store.applyItemAttachments(
            [
                TestFixtures.makeItemAttachmentDTO(id: keepId, tripId: tripA),
                TestFixtures.makeItemAttachmentDTO(id: goneId, tripId: tripA),
                TestFixtures.makeItemAttachmentDTO(id: pendingId, tripId: tripA)
            ], tripId: tripA
        )
        try await store.applyItemAttachments(
            [TestFixtures.makeItemAttachmentDTO(id: otherTripId, tripId: tripB)], tripId: tripB
        )

        // pendingId has an unpushed local delete sitting in the outbox.
        try await store.enqueueDelete(table: .itemAttachments, rowId: pendingId, tripId: tripA)

        // Latest pull for tripA only returns keepId — goneId and pendingId
        // are absent server-side (from this pull's point of view).
        try await store.applyItemAttachments(
            [TestFixtures.makeItemAttachmentDTO(id: keepId, tripId: tripA)], tripId: tripA
        )

        let rows = try context.fetch(FetchDescriptor<ItemAttachment>())
        let idsByTrip = Dictionary(grouping: rows, by: \.tripId).mapValues { Set($0.map(\.id)) }

        XCTAssertEqual(idsByTrip[tripA], [keepId, pendingId], "goneId is deleted; pendingId survives its pending op")
        XCTAssertEqual(idsByTrip[tripB], [otherTripId], "tripB's row is untouched by a tripA-scoped pull")
    }

    /// Principle 2 (SYNC_DESIGN.md): a pull never clobbers a pending row's
    /// fields, not just its existence.
    func testApplyNeverOverwritesFieldsOfARowWithAPendingOp() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)
        let tripId = UUID()
        let id = UUID()

        try await store.applyItemAttachments(
            [TestFixtures.makeItemAttachmentDTO(id: id, tripId: tripId, fileName: "local-pending.pdf")], tripId: tripId
        )
        try await store.enqueueUpsert(table: .itemAttachments, rowId: id, tripId: tripId, payloadJSON: "{}")

        // A stale server view still reports the old name — must not clobber.
        try await store.applyItemAttachments(
            [TestFixtures.makeItemAttachmentDTO(id: id, tripId: tripId, fileName: "stale-server-name.pdf")], tripId: tripId
        )

        let rows = try context.fetch(FetchDescriptor<ItemAttachment>())
        XCTAssertEqual(rows.first?.fileName, "local-pending.pdf")
    }

    /// D1: a malformed row must never look like a server-side delete —
    /// same rule `PullApplyReconcileTests` pins for `profiles`/`trips`.
    func testSkippedCountBlanksTheWholeDeletePhase() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)
        let tripId = UUID()
        let staleId = UUID()

        try await store.applyItemAttachments([TestFixtures.makeItemAttachmentDTO(id: staleId, tripId: tripId)], tripId: tripId)

        // This pull's own decode dropped a malformed row — staleId is
        // absent from `dtos` but must survive since skippedCount > 0.
        try await store.applyItemAttachments([], tripId: tripId, skippedCount: 1)

        let rows = try context.fetch(FetchDescriptor<ItemAttachment>())
        XCTAssertEqual(rows.map(\.id), [staleId], "a row absent only because THIS pull skipped a malformed row must survive")
    }

    func testPruneOrphansRemovesAttachmentsWhoseTripDisappeared() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let keepTripId = UUID()
        let goneTripId = UUID()
        // Only the surviving trip has a local `Trip` row — mirrors a trip
        // that was deleted/membership-revoked elsewhere and already pruned.
        context.insert(Trip(dto: TestFixtures.makeTripDTO(id: keepTripId)))
        context.insert(ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(tripId: keepTripId)))
        let goneId = UUID()
        context.insert(ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(id: goneId, tripId: goneTripId)))
        try context.save()

        try await store.pruneOrphans()

        let remaining = try context.fetch(FetchDescriptor<ItemAttachment>())
        XCTAssertEqual(remaining.map(\.tripId), [keepTripId])
    }

    func testPruneOrphansProtectsAttachmentsWithAPendingOpEvenIfTheirTripDisappeared() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let context = ModelContext(container)

        let goneTripId = UUID()
        let pendingId = UUID()
        context.insert(ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(id: pendingId, tripId: goneTripId)))
        try context.save()
        try await store.enqueueUpsert(table: .itemAttachments, rowId: pendingId, tripId: goneTripId, payloadJSON: "{}")

        try await store.pruneOrphans()

        let remaining = try context.fetch(FetchDescriptor<ItemAttachment>())
        XCTAssertEqual(remaining.map(\.id), [pendingId])
    }

    // MARK: - Prefetch query (SyncStore.attachmentsStartingSoon)

    func testAttachmentsStartingSoonReturnsOnlyAttachmentsOnItemsWithinTheWindow() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let store = SyncStore(modelContainer: container)
        let tripId = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let soonItem = TestFixtures.makeItineraryItem(tripId: tripId, startsAt: now.addingTimeInterval(3 * 86_400))
        let farItem = TestFixtures.makeItineraryItem(tripId: tripId, startsAt: now.addingTimeInterval(30 * 86_400))
        let pastItem = TestFixtures.makeItineraryItem(tripId: tripId, startsAt: now.addingTimeInterval(-86_400))
        context.insert(soonItem)
        context.insert(farItem)
        context.insert(pastItem)

        let soonAttachment = ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(tripId: tripId, itemId: soonItem.id))
        let farAttachment = ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(tripId: tripId, itemId: farItem.id))
        let pastAttachment = ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(tripId: tripId, itemId: pastItem.id))
        context.insert(soonAttachment)
        context.insert(farAttachment)
        context.insert(pastAttachment)
        try context.save()

        let candidates = try await store.attachmentsStartingSoon(tripId: tripId, within: 7, now: now)

        XCTAssertEqual(candidates.map(\.id), [soonAttachment.id], "only the item starting within the window prefetches")
    }

    func testAttachmentsStartingSoonReturnsEmptyWhenNoItemIsInTheWindow() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let store = SyncStore(modelContainer: container)
        let tripId = UUID()
        let now = Date(timeIntervalSince1970: 1_000_000)

        let farItem = TestFixtures.makeItineraryItem(tripId: tripId, startsAt: now.addingTimeInterval(30 * 86_400))
        context.insert(farItem)
        context.insert(ItemAttachment(dto: TestFixtures.makeItemAttachmentDTO(tripId: tripId, itemId: farItem.id)))
        try context.save()

        let candidates = try await store.attachmentsStartingSoon(tripId: tripId, within: 7, now: now)
        XCTAssertTrue(candidates.isEmpty)
    }
}
