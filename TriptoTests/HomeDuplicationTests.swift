import SwiftData
import XCTest
@testable import Tripto

/// D1 (qa) regression: duplicating a past trip that was never opened this
/// session must still copy its items. `pullHome` only loads the home-scope
/// tables — itinerary items/packing enter the local mirror solely via
/// `pullTrip`, which runs on trip-open (`SyncEngine+Pull`/`TripView`). Before
/// the fix, `HomeView.duplicateContent` cloned straight from that (empty)
/// local set and its empty-source guard reported success anyway: an itemless
/// copy whose `.next` "FIRST UP" strip was permanently absent and survived a
/// cold relaunch. `HomeDuplication.cloneContent` now pulls the source first.
///
/// The pull is injected, so this stays hermetic: the closure applies the
/// source's rows with the very same `SyncStore.applyItineraryItems` a real
/// `pullTrip` runs — no network. Removing the `await ensureSourceLoaded()`
/// from `cloneContent` makes the "cloned" assertion below fail, which is the
/// point.
final class HomeDuplicationTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    @MainActor
    func testDuplicatingATripWhoseItemsArentLocallyCachedPullsThemFirstSoTheStripSurvives() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let store = SyncStore(modelContainer: container)
        let userId = UUID()

        let sourceTripId = UUID()
        let sourceStart = utc.date(byAdding: .day, value: -120, to: utc.startOfDay(for: .now))!
        // The source trip is visible on Home (home-scope pull) but was never
        // opened, so its items are NOT local — only server-side. Held as the
        // DTOs a `pullTrip` would fetch.
        let sourceItemDTOs: [ItineraryItemDTO] = (0..<3).map { day in
            TestFixtures.makeItineraryItem(
                tripId: sourceTripId,
                startsAt: utc.date(byAdding: .day, value: day, to: sourceStart)!.addingTimeInterval(9 * 3600),
                tz: "Europe/Lisbon", status: .confirmed, createdBy: userId
            ).toDTO()
        }

        let newTripId = UUID()
        let newStart = utc.startOfDay(for: utc.date(byAdding: .day, value: 9, to: .now)!)

        // Pre-fix behavior (no pull): the local fetch is empty, nothing clones.
        let unpulled = await HomeDuplication.cloneContent(
            sourceTripId: sourceTripId, sourceStart: sourceStart, newTripId: newTripId, newStart: newStart,
            createdBy: userId, modelContext: context, ensureSourceLoaded: {}
        )
        XCTAssertEqual(unpulled?.items.count, 0, "without a pull the source items aren't local — this is the bug")

        // With the fix's pull (apply the source's rows exactly as pullTrip does):
        let cloned = await HomeDuplication.cloneContent(
            sourceTripId: sourceTripId, sourceStart: sourceStart, newTripId: newTripId, newStart: newStart,
            createdBy: userId, modelContext: context,
            ensureSourceLoaded: { try? await store.applyItineraryItems(sourceItemDTOs, tripId: sourceTripId) }
        )
        XCTAssertEqual(cloned?.items.count, 3, "the source's items must be pulled into the mirror, then cloned")

        // The new trip's FIRST UP strip now resolves from what's on disk.
        let onDisk = try context.fetch(FetchDescriptor<ItineraryItem>(
            predicate: #Predicate<ItineraryItem> { $0.tripId == newTripId }
        )).filter { $0.status == .confirmed }
        XCTAssertEqual(onDisk.count, 3, "cloned items must be persisted on the new trip")
        XCTAssertNotNil(
            HomeFirstUp.pick(from: onDisk),
            "a properly duplicated future trip must surface a FIRST UP item"
        )
    }

    /// The genuinely-empty source stays a success (an empty trip is a valid
    /// template) — the fix must not turn "nothing to copy" into a failure.
    @MainActor
    func testDuplicatingAGenuinelyEmptySourceStillSucceedsWithNothingToClone() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)
        let cloned = await HomeDuplication.cloneContent(
            sourceTripId: UUID(), sourceStart: .now, newTripId: UUID(),
            newStart: utc.date(byAdding: .day, value: 9, to: .now)!,
            createdBy: UUID(), modelContext: context, ensureSourceLoaded: {}
        )
        XCTAssertNotNil(cloned, "an empty source is not a save failure")
        XCTAssertEqual(cloned?.items.count, 0)
        XCTAssertEqual(cloned?.packing.count, 0)
    }
}
