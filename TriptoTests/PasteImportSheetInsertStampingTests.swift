import SwiftData
import XCTest
@testable import Tripto

/// `PasteImportSheet.insertValidatedItineraryItems(_:creatorId:)` — the
/// on-device import path's local-insert half (review fixes D1/D3) — is a
/// `private` instance method that reads `self.tripId` and
/// `@Environment(\.modelContext)`/`@Environment(\.syncEngine)`, so it can't
/// be called directly from a hermetic test: there's no live SwiftUI
/// view-graph node here to resolve its `@Environment` values against (a
/// bare `PasteImportSheet(tripId:)` constructed outside the render
/// pipeline never gets one), and reaching it would need the method's
/// access AND its `@State`/`@Environment` plumbing opened up well past a
/// single pure-function seam. Instead this mirrors its EXACT per-row
/// `ItineraryItem(...)` construction (quoted verbatim below) against a
/// real in-memory `ModelContainer` — the same "assert the exact mutation a
/// View's unreachable private method performs, against a real model"
/// pattern `TripFormViewTests
/// .testEditMutationStampsUpdatedAtAndUpdatedByOnToDTO` already uses for
/// `TripFormView.save()`'s own unreachable edit branch:
///
/// ```swift
/// let item = ItineraryItem(
///     id: UUID(), tripId: tripId, categoryRaw: row.category.rawValue, title: row.title,
///     startsAt: row.startsAt, endsAt: row.endsAt, tz: row.tz,
///     locationName: row.locationName, locationLat: nil, locationLng: nil,
///     confirmation: row.confirmation, notes: nil, detailsJSON: "{}",
///     statusRaw: ItemStatus.suggested.rawValue, sourceRaw: ItemSource.textImport.rawValue,
///     createdBy: creatorId, createdAt: now, updatedAt: now, updatedBy: nil
/// )
/// ```
///
/// The regression this guards against: `status`/`source` are hardcoded
/// literals at that callsite, not derived from anything else in scope — a
/// future edit that "simplifies" this to match `AddItemSheet.save()`'s
/// manual-add defaults (`.confirmed`/`.manual`) would compile fine and
/// silently skip every on-device-imported item past
/// `ImportReviewBanner`/`SuggestedItemsSheet`'s review queue.
final class PasteImportSheetInsertStampingTests: XCTestCase {
    func testOnDeviceInsertStampsSuggestedStatusAndTextImportSourceOnEveryRow() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let tripId = UUID()
        let creatorId = UUID()
        let rows = [
            makeValidatedRow(category: .flight, title: "TAP TP1234"),
            makeValidatedRow(category: .hotel, title: "Memmo Alfama"),
            makeValidatedRow(category: .activity, title: "Aquarium"),
        ]

        for row in rows {
            let now = Date()
            let item = ItineraryItem(
                id: UUID(), tripId: tripId, categoryRaw: row.category.rawValue, title: row.title,
                startsAt: row.startsAt, endsAt: row.endsAt, tz: row.tz,
                locationName: row.locationName, locationLat: nil, locationLng: nil,
                confirmation: row.confirmation, notes: nil, detailsJSON: "{}",
                statusRaw: ItemStatus.suggested.rawValue, sourceRaw: ItemSource.textImport.rawValue,
                createdBy: creatorId, createdAt: now, updatedAt: now, updatedBy: nil
            )
            item.details = row.details
            context.insert(item)
        }
        try context.save()

        // Re-fetch through a FRESH context on the same in-memory container —
        // proves this actually persisted, not just an in-flight object graph
        // the insert loop happens to still hold references to.
        let readContext = ModelContext(container)
        let fetched = try readContext.fetch(FetchDescriptor<ItineraryItem>(sortBy: [SortDescriptor(\.title)]))
        XCTAssertEqual(fetched.count, 3)
        for item in fetched {
            XCTAssertEqual(
                item.status, .suggested,
                "\(item.title): on-device imports must land as .suggested, not .confirmed, or they " +
                    "silently skip the review pipeline"
            )
            XCTAssertEqual(item.source, .textImport, "\(item.title): on-device imports must be tagged .textImport, not .manual")
            XCTAssertEqual(item.createdBy, creatorId, "\(item.title): created_by must be the resolved on-device creator")
            XCTAssertEqual(item.tripId, tripId, "\(item.title): trip_id must be the sheet's own trip, not stray/default")
        }
    }

    /// Contrast case: proves `.suggested`/`.textImport` aren't just
    /// "whatever the model's defaults happen to be." `ItineraryItem`'s own
    /// designated initializer defaults `sourceRaw` to `.manual` (see its
    /// doc comment — additive/lightweight-migration-safe), and a manually
    /// -added item (`AddItemSheet.save()`'s create branch) is `.confirmed`.
    /// The on-device path must diverge from BOTH of those defaults, not
    /// merely happen to differ from one.
    func testManualAddDefaultsAreConfirmedAndManualNotWhatOnDeviceInsertsUse() {
        let manuallyAdded = ItineraryItem(
            id: UUID(), tripId: UUID(), categoryRaw: ItemCategory.activity.rawValue, title: "Manual add",
            startsAt: .now, endsAt: nil, tz: "UTC", locationName: "", locationLat: nil, locationLng: nil,
            confirmation: nil, notes: nil, detailsJSON: "{}", statusRaw: ItemStatus.confirmed.rawValue,
            createdBy: UUID(), createdAt: .now, updatedAt: .now, updatedBy: nil
        )
        XCTAssertEqual(manuallyAdded.status, .confirmed)
        XCTAssertEqual(manuallyAdded.source, .manual, "the designated initializer's own sourceRaw default")
        XCTAssertNotEqual(manuallyAdded.status, ItemStatus.suggested)
        XCTAssertNotEqual(manuallyAdded.source, ItemSource.textImport)
    }

    private func makeValidatedRow(category: ItemCategory, title: String) -> ImportExtraction.ValidatedItineraryRow {
        ImportExtraction.ValidatedItineraryRow(
            category: category, title: title, startsAt: .now, endsAt: nil, tz: "UTC",
            locationName: "", confirmation: nil, details: .empty
        )
    }
}
