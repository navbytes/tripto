import SwiftData
import XCTest
@testable import Tripto

/// P6.2 (docs/UX_REDESIGN_ROADMAP.md): `TripMerge.execute`'s SwiftData move
/// — same hermetic, in-memory-container shape as `HomeDuplicationTests`.
/// `ensureBothLoaded` is injected so this stays hermetic (no network),
/// applying rows via `SyncStore.applyItineraryItems` exactly like a real
/// `pullTrip` would.
final class TripMergeTests: XCTestCase {
    @MainActor
    func testMergeMovesItemsPackingAndProfilesFromShellToSurvivor() async throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let userId = UUID()
        let shellId = UUID()
        let survivorId = UUID()

        let item = TestFixtures.makeItineraryItem(tripId: shellId, startsAt: .now, createdBy: userId)
        context.insert(item)
        let packing = PackingItem(
            id: UUID(), tripId: shellId, label: "Sunscreen", groupKeyRaw: PackingGroupKey.shared.rawValue,
            assigneeProfileId: nil, isDone: false, createdBy: userId, createdAt: .now, updatedAt: .now, updatedBy: nil
        )
        context.insert(packing)
        let profile = TripProfile(id: UUID(), tripId: shellId, displayName: "Grandma", avatarColor: "sky", linkedUserId: nil, createdAt: .now)
        context.insert(profile)
        try context.save()

        let moved = await TripMerge.execute(
            shellTripId: shellId, survivorTripId: survivorId, modelContext: context, ensureBothLoaded: {}
        )

        XCTAssertEqual(moved?.items.count, 1)
        XCTAssertEqual(moved?.packing.count, 1)
        XCTAssertEqual(moved?.profiles.count, 1)

        let itemsOnSurvivor = try context.fetch(FetchDescriptor<ItineraryItem>(
            predicate: #Predicate<ItineraryItem> { $0.tripId == survivorId }
        ))
        XCTAssertEqual(itemsOnSurvivor.count, 1)
        let packingOnSurvivor = try context.fetch(FetchDescriptor<PackingItem>(
            predicate: #Predicate<PackingItem> { $0.tripId == survivorId }
        ))
        XCTAssertEqual(packingOnSurvivor.count, 1)
        let profilesOnSurvivor = try context.fetch(FetchDescriptor<TripProfile>(
            predicate: #Predicate<TripProfile> { $0.tripId == survivorId }
        ))
        XCTAssertEqual(profilesOnSurvivor.count, 1)

        // Nothing left behind on the shell — these are re-pointed in
        // place, not copied.
        XCTAssertTrue(try context.fetch(FetchDescriptor<ItineraryItem>(
            predicate: #Predicate<ItineraryItem> { $0.tripId == shellId }
        )).isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<TripProfile>(
            predicate: #Predicate<TripProfile> { $0.tripId == shellId }
        )).isEmpty)
    }

    /// nt lesson YEFXVP: a shell trip never opened this session has
    /// nothing local to move — `ensureBothLoaded` must run BEFORE the
    /// fetch, or this silently "succeeds" with zero rows moved (the exact
    /// P5 bug this phase was warned to avoid repeating).
    @MainActor
    func testMergingAShellTripNeverOpenedThisSessionPullsItsItemsFirst() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let store = SyncStore(modelContainer: container)
        let shellId = UUID()
        let survivorId = UUID()
        let itemDTO = TestFixtures.makeItineraryItem(tripId: shellId, startsAt: .now).toDTO()

        let unpulled = await TripMerge.execute(
            shellTripId: shellId, survivorTripId: survivorId, modelContext: context, ensureBothLoaded: {}
        )
        XCTAssertEqual(unpulled?.items.count, 0, "without a pull the shell's items aren't local — this is the bug")

        let pulled = await TripMerge.execute(
            shellTripId: shellId, survivorTripId: survivorId, modelContext: context,
            ensureBothLoaded: { try? await store.applyItineraryItems([itemDTO], tripId: shellId) }
        )
        XCTAssertEqual(pulled?.items.count, 1, "the shell's items must be pulled into the mirror, then moved")
    }

    /// An itemless/packing-less/profile-less shell is still a success — a
    /// genuinely empty trip is a valid (if pointless) thing to merge away,
    /// same "empty source isn't a failure" rule `HomeDuplication` uses.
    @MainActor
    func testMergingAGenuinelyEmptyShellStillSucceedsWithNothingMoved() async throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let moved = await TripMerge.execute(
            shellTripId: UUID(), survivorTripId: UUID(), modelContext: context, ensureBothLoaded: {}
        )
        XCTAssertNotNil(moved)
        XCTAssertEqual(moved?.items.count, 0)
        XCTAssertEqual(moved?.packing.count, 0)
        XCTAssertEqual(moved?.profiles.count, 0)
    }
}
