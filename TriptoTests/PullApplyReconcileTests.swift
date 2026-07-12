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

    /// D1: the core rule the security finding is about, pinned at the
    /// cheapest layer — a nonzero `skippedCount` (this table's pull dropped
    /// a malformed row) must blank the whole delete phase, not just narrow
    /// it, even though `existing` is otherwise a plain "absent from the
    /// pull" candidate.
    func testIdsToDeleteSkipsTheWholeDeletePhaseWhenSkippedCountIsNonZero() {
        let existing = UUID()
        let result = SyncReconcile.idsToDelete(
            existingIds: [existing], pulledIds: [], pendingIds: [], skippedCount: 1
        )
        XCTAssertTrue(result.isEmpty, "a pull that dropped a malformed row must not treat any local row as server-deleted")
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
            TestFixtures.makeTripDTO(id: pendingId, title: "Pending edit")
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

    // MARK: - D1: a malformed row must never look like a server-side delete

    /// Same "one bad row, `display_name` a number instead of a string" shape
    /// `LossyCodableListTests` uses, but with the malformed row's `id`
    /// caller-controlled so a test can assert on whether the local row that
    /// shares its identity survives. Goes through the real decode path
    /// (`LossyCodableList<ProfileDTO>`, not hand-built DTOs) so `skippedCount`
    /// is genuine, not asserted-into-existence.
    private func profilesJSON(valid: [(id: UUID, name: String)], malformedId: UUID?) -> Data {
        var rows = valid.map { id, name in
            """
            {"id":"\(id.uuidString)","display_name":"\(name)","avatar_color":"coral","created_at":"2026-07-08T12:34:56.789+00:00","updated_at":"2026-07-08T12:34:56.789+00:00"}
            """
        }
        if let malformedId {
            rows.append(
                """
                {"id":"\(malformedId.uuidString)","display_name":42,"avatar_color":"coral","created_at":"2026-07-08T12:34:56.789+00:00","updated_at":"2026-07-08T12:34:56.789+00:00"}
                """
            )
        }
        return Data("[\(rows.joined(separator: ","))]".utf8)
    }

    /// The security finding itself: a local, non-pending row survives a
    /// pull where its server-side counterpart merely failed tolerant
    /// decode this time — it must not be silently deleted, and the rows
    /// that did decode must still upsert, with no throw (pull "succeeds").
    func testMalformedRowInPullDoesNotDeleteTheLocalRowSharingItsIdentity() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)

        let staleId = UUID() // exists locally; fails to decode on the next pull
        let keepA = UUID()
        let keepB = UUID()

        // Seed local state as if an earlier, fully-successful pull brought
        // all three rows in.
        try await store.applyProfiles([
            ProfileDTO(id: staleId, displayName: "Cam", avatarColor: "coral", createdAt: .now, updatedAt: .now),
            ProfileDTO(id: keepA, displayName: "Ana (old)", avatarColor: "coral", createdAt: .now, updatedAt: .now),
            ProfileDTO(id: keepB, displayName: "Bo", avatarColor: "coral", createdAt: .now, updatedAt: .now)
        ])

        // Next pull: keepA/keepB decode fine (keepA renamed server-side);
        // staleId's row is malformed this time, so it's skipped, not gone.
        let json = profilesJSON(valid: [(keepA, "Ana"), (keepB, "Bo")], malformedId: staleId)
        let decoded = try JSONCoding.decoder.decode(LossyCodableList<ProfileDTO>.self, from: json)
        XCTAssertEqual(decoded.skippedCount, 1)

        try await store.applyProfiles(decoded.elements, skippedCount: decoded.skippedCount)

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<Profile>())
        let byId = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

        XCTAssertEqual(rows.count, 3, "the malformed row's local counterpart must not be deleted")
        XCTAssertNotNil(byId[staleId], "a row that only failed to decode this pull must survive, not look server-deleted")
        XCTAssertEqual(byId[keepA]?.displayName, "Ana", "rows that did decode must still upsert normally")
        XCTAssertEqual(byId[keepB]?.displayName, "Bo")
    }

    /// Regression guard (no behavior change when `skippedCount == 0`): same
    /// shape as above, but nothing fails to decode this time — a row
    /// genuinely absent from the pull must still be deleted, same as before
    /// this fix.
    func testGenuinelyAbsentRowIsStillDeletedWhenNothingWasSkipped() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)

        let goneId = UUID()
        let keepA = UUID()
        let keepB = UUID()

        try await store.applyProfiles([
            ProfileDTO(id: goneId, displayName: "Cam", avatarColor: "coral", createdAt: .now, updatedAt: .now),
            ProfileDTO(id: keepA, displayName: "Ana", avatarColor: "coral", createdAt: .now, updatedAt: .now),
            ProfileDTO(id: keepB, displayName: "Bo", avatarColor: "coral", createdAt: .now, updatedAt: .now)
        ])

        // goneId is genuinely absent this pull — no malformed rows at all.
        let json = profilesJSON(valid: [(keepA, "Ana"), (keepB, "Bo")], malformedId: nil)
        let decoded = try JSONCoding.decoder.decode(LossyCodableList<ProfileDTO>.self, from: json)
        XCTAssertEqual(decoded.skippedCount, 0)

        try await store.applyProfiles(decoded.elements, skippedCount: decoded.skippedCount)

        let context = ModelContext(container)
        let rows = try context.fetch(FetchDescriptor<Profile>())
        XCTAssertEqual(
            Set(rows.map(\.id)), [keepA, keepB],
            "a row genuinely absent from the pull must still be deleted when nothing was skipped"
        )
    }
}
