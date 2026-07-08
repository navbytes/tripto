import SwiftData
import XCTest
@testable import Tripto

/// SYNC_DESIGN.md: "Apply = upsert by id; then delete local rows absent
/// from the server response unless they have a pending outbox op."
final class PullApplyReconcileTests: XCTestCase {
    func testIdsToDeleteExcludesPulledAndPendingRows() {
        let keep = UUID()
        let gone = UUID()
        let pending = UUID()

        let result = SyncReconcile.idsToDelete(
            existingIds: [keep, gone, pending],
            pulledIds: [keep],
            pendingIds: [pending]
        )

        XCTAssertEqual(result, [gone])
    }

    func testIdsToDeleteIsEmptyWhenNothingIsAbsent() {
        let a = UUID()
        let b = UUID()
        let result = SyncReconcile.idsToDelete(existingIds: [a, b], pulledIds: [a, b], pendingIds: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testApplyTripsDeletesAbsentRowsButProtectsPendingOnes() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)

        let keepId = UUID()
        let goneId = UUID()
        let pendingId = UUID()

        // Seed three local trips as if a previous pull had brought them in.
        try await store.applyTrips([
            TestFixtures.makeTripDTO(id: keepId, title: "Keep"),
            TestFixtures.makeTripDTO(id: goneId, title: "Gone"),
            TestFixtures.makeTripDTO(id: pendingId, title: "Pending edit"),
        ])

        // pendingId has an unpushed local edit sitting in the outbox.
        try await store.enqueueUpsert(
            table: .trips, rowId: pendingId, tripId: pendingId, payloadJSON: #"{"title":"Local edit"}"#
        )

        // Latest pull only returns keepId — goneId and pendingId are absent.
        try await store.applyTrips([TestFixtures.makeTripDTO(id: keepId, title: "Keep")])

        let context = ModelContext(container)
        let remaining = try context.fetch(FetchDescriptor<Trip>())
        let remainingIds = Set(remaining.map(\.id))
        let remainingById = Dictionary(uniqueKeysWithValues: remaining.map { ($0.id, $0) })

        XCTAssertTrue(remainingIds.contains(keepId))
        XCTAssertFalse(remainingIds.contains(goneId), "a row absent from the pull with no pending op must be deleted")
        XCTAssertTrue(
            remainingIds.contains(pendingId),
            "a row absent from the pull but with a pending op must survive"
        )
        // Principle 2: a pull never clobbers a pending row's fields either,
        // not just its existence.
        XCTAssertEqual(remainingById[pendingId]?.title, "Pending edit")
    }

    func testApplyTripsUpsertsExistingRowsInPlace() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let id = UUID()

        try await store.applyTrips([TestFixtures.makeTripDTO(id: id, title: "Original")])
        try await store.applyTrips([TestFixtures.makeTripDTO(id: id, title: "Renamed")])

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<Trip>())
        XCTAssertEqual(rows.count, 1, "an upsert-by-id must update in place, never duplicate")
        XCTAssertEqual(rows.first?.title, "Renamed")
    }
}
