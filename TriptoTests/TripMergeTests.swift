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

    /// Collision handling: `execute` never compares the shell's rows against
    /// the survivor's own — it only moves rows whose `tripId` matches the
    /// shell. Two items independently sitting at the exact same instant (one
    /// per trip) are both KEPT after the merge, not deduplicated — pins the
    /// actual (simple, by-design) behavior so a future change couldn't add
    /// silent content-based deduping (or accidentally drop one) unnoticed.
    @MainActor
    func testMergeKeepsBothItemsWhenShellAndSurvivorHaveItemsAtTheIdenticalInstant() async throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let shellId = UUID()
        let survivorId = UUID()
        let sharedInstant = Date(timeIntervalSince1970: 1_800_000_000)

        let shellItem = TestFixtures.makeItineraryItem(tripId: shellId, title: "Shell's own item", startsAt: sharedInstant)
        let survivorItem = TestFixtures.makeItineraryItem(tripId: survivorId, title: "Survivor's own item", startsAt: sharedInstant)
        context.insert(shellItem)
        context.insert(survivorItem)
        try context.save()

        let moved = await TripMerge.execute(
            shellTripId: shellId, survivorTripId: survivorId, modelContext: context, ensureBothLoaded: {}
        )
        XCTAssertEqual(moved?.items.map(\.id), [shellItem.id], "only the shell's own row is reported as moved")

        let onSurvivor = try context.fetch(FetchDescriptor<ItineraryItem>(
            predicate: #Predicate<ItineraryItem> { $0.tripId == survivorId }
        ))
        XCTAssertEqual(
            Set(onSurvivor.map(\.id)), Set([shellItem.id, survivorItem.id]),
            "an identical-time collision is kept, not merged/deduplicated — both rows survive independently"
        )
    }

    /// "App killed mid-countdown" (`HomeView.startMerge`'s own doc comment:
    /// nothing touches the model or the network until the 6s countdown
    /// elapses uncancelled) — from the model's point of view this is
    /// indistinguishable from "the user never tapped Merge at all", since
    /// `TripMerge.execute` is simply never invoked during the countdown.
    /// Confirms both halves of that claim against real persistence rather
    /// than just reasoning about the code: the shell/survivor rows are
    /// completely untouched, and a brand new `ModelContext` against the same
    /// store (standing in for "next launch's fresh `@Query`") re-detects the
    /// identical duplicate pair — the strip reappears with nothing to
    /// reconcile, no partial merge left behind.
    @MainActor
    func testKillingTheAppMidCountdownLeavesBothTripsIntactAndTheStripReappearsOnRelaunch() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let end = start.addingTimeInterval(4 * 86_400)
        let shell = TestFixtures.makeTrip(destination: "Okinawa, Japan", startDate: start, endDate: end)
        let survivor = TestFixtures.makeTrip(destination: "Okinawa, Japan", startDate: start, endDate: end)
        let shellId = shell.id
        let shellItem = TestFixtures.makeItineraryItem(tripId: shellId, startsAt: start)
        context.insert(shell)
        context.insert(survivor)
        context.insert(shellItem)
        try context.save()

        // The 6s countdown elapsing uncancelled is the ONLY path to
        // `TripMerge.execute` — deliberately never called here, simulating
        // the app dying at any point during the window.

        // "Next launch": a fresh context against the same store, exactly
        // what a relaunch's own `@Query` would read back.
        let relaunchContext = ModelContext(container)
        let trips = try relaunchContext.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate)]))
        XCTAssertEqual(trips.count, 2, "no trip was deleted — the merge never actually ran")
        let itemsStillOnShell = try relaunchContext.fetch(FetchDescriptor<ItineraryItem>(
            predicate: #Predicate<ItineraryItem> { $0.tripId == shellId }
        ))
        XCTAssertEqual(itemsStillOnShell.count, 1, "the shell's item was never moved")

        let pair = TripMergeDetection.survivorByShellId(in: trips)
        XCTAssertFalse(pair.isEmpty, "detection is re-derived fresh from persisted trips, not cached state — the strip must reappear")
    }
}
