import SwiftData
import XCTest
@testable import Tripto

/// P4.3 (docs/UX_REDESIGN_ROADMAP.md): the Export row's "N trips · M items"
/// subtitle — pure pluralization, same convention `SettingsView`'s own
/// (private) `importSummary(_:)` already uses for the import-result alert.
final class SettingsExportCountsTests: XCTestCase {
    func testSingularTripAndItem() {
        XCTAssertEqual(SettingsView.exportCountsText(tripCount: 1, itemCount: 1), "1 trip \u{00B7} 1 item")
    }

    func testPluralTripsAndItems() {
        XCTAssertEqual(SettingsView.exportCountsText(tripCount: 20, itemCount: 67), "20 trips \u{00B7} 67 items")
    }

    func testZeroCountsStillPluralize() {
        XCTAssertEqual(SettingsView.exportCountsText(tripCount: 0, itemCount: 0), "0 trips \u{00B7} 0 items")
    }

    func testMixedSingularAndPlural() {
        XCTAssertEqual(SettingsView.exportCountsText(tripCount: 1, itemCount: 5), "1 trip \u{00B7} 5 items")
        XCTAssertEqual(SettingsView.exportCountsText(tripCount: 5, itemCount: 1), "5 trips \u{00B7} 1 item")
    }

    // MARK: - Parity: the displayed count vs. what composeDocument actually exports
    //
    // P4.3's whole point ("the count on screen can never disagree with what
    // tapping the row will actually export") only holds if `SettingsView`'s
    // two unfiltered `@Query`s and `TripArchiveExporter.composeDocument`'s
    // trip/item arrays stay in lockstep. This pins that with a real
    // in-memory store containing an item that hasn't synced yet — a genuine
    // `OutboxOp` row referencing it, the only place "pending sync" is
    // actually tracked in this schema (`ItineraryItem`/`Trip` carry no
    // sync-status column of their own; `SyncStatus.pendingCount` is itself
    // just a count of these same rows). There is also no soft-delete concept
    // anywhere in this schema to test alongside it — no `deletedAt`/
    // `isDeleted` column on any model (confirmed by grep); `deleteTrip()`/
    // `removeMember()`/etc. all do a real `modelContext.delete(_:)`, so
    // there's nothing "locally soft-deleted" left over to include here.

    @MainActor
    func testExportedCountsMatchTheRawFetchedCountsIncludingAPendingSyncItem() throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let tripId = UUID()
        let trip = TestFixtures.makeTrip(id: tripId, startDate: .now, endDate: .now.addingTimeInterval(86_400))
        let syncedItem = TestFixtures.makeItineraryItem(tripId: tripId, startsAt: .now)
        let pendingItem = TestFixtures.makeItineraryItem(tripId: tripId, startsAt: .now.addingTimeInterval(3_600))
        context.insert(trip)
        context.insert(syncedItem)
        context.insert(pendingItem)
        // The one real "hasn't synced yet" marker: an outstanding `OutboxOp`
        // row for `pendingItem`, exactly what `SyncEngine.enqueueUpsert`
        // writes for a not-yet-pushed local edit. Never flushed/deleted
        // here, so it stays pending for the life of this test.
        context.insert(OutboxOp(
            tableRaw: SyncTable.itineraryItems.rawValue, opRaw: OutboxOpKind.upsert.rawValue,
            rowId: pendingItem.id, tripId: tripId, payloadJSON: "{}"
        ))
        try context.save()

        // Mirrors both call sites this contract has to hold between:
        // `SettingsView`'s own unfiltered `@Query`s (what the subtitle
        // counts) and `exportArchive()`'s own unfiltered `FetchDescriptor`
        // fetch (what actually gets composed and written out).
        let fetchedTrips = try context.fetch(FetchDescriptor<Trip>())
        let fetchedItems = try context.fetch(FetchDescriptor<ItineraryItem>())
        XCTAssertEqual(fetchedTrips.count, 1)
        XCTAssertEqual(fetchedItems.count, 2, "the pending-sync item must still be fetched, not filtered out")

        let displayedCounts = SettingsView.exportCountsText(tripCount: fetchedTrips.count, itemCount: fetchedItems.count)
        XCTAssertEqual(displayedCounts, "1 trip \u{00B7} 2 items")

        let document = TripArchiveExporter.composeDocument(trips: fetchedTrips, items: fetchedItems, profiles: [])
        XCTAssertEqual(document.trips.count, fetchedTrips.count, "export dropped a trip the displayed count included")
        let exportedItemCount = document.trips.reduce(0) { $0 + $1.items.count }
        XCTAssertEqual(exportedItemCount, fetchedItems.count, "export dropped an item the displayed count included")
        // The pending item specifically made it into the export — not just
        // some other unrelated item coincidentally matching the total.
        XCTAssertTrue(
            document.trips.first?.items.contains { $0.id == pendingItem.id.uuidString } ?? false,
            "the pending-sync item itself is missing from the export"
        )
    }
}
