import SwiftData
import XCTest

// Reviewer HIGH (2026-07-21): a suggesting viewer must never see the
// paste/email-import entries — the paste flow's packing branch inserts rows
// the viewer RLS denies. Pins the pure gate the sheet body uses.
@MainActor
final class AddItemSheetImportEntriesGateTests: XCTestCase {
    func testImportEntriesHiddenWhileSuggesting() {
        XCTAssertFalse(AddItemSheet.showsImportEntries(isEditing: false, isSuggesting: true))
    }

    func testImportEntriesVisibleForNormalAdd() {
        XCTAssertTrue(AddItemSheet.showsImportEntries(isEditing: false, isSuggesting: false))
    }

    func testImportEntriesHiddenWhileEditing() {
        XCTAssertFalse(AddItemSheet.showsImportEntries(isEditing: true, isSuggesting: false))
    }
}
@testable import Tripto

/// `AddItemSheet.save()`'s create branch — a `private` instance method that
/// reads `@State`/`@Environment` values no bare `AddItemSheet(...)` built
/// outside the render pipeline ever resolves — can't be called directly
/// from a hermetic test, same unreachable-private-method situation
/// `PasteImportSheetInsertStampingTests`'s own doc comment already explains
/// for `PasteImportSheet.insertValidatedItineraryItems`. This mirrors ITS
/// pattern: assert the exact `ItineraryItem(...)` construction the suggest-
/// tray branch (BRIEF.md) now performs, quoted verbatim below, against a
/// real in-memory `ModelContainer`.
///
/// ```swift
/// let item = ItineraryItem(
///     id: UUID(), tripId: tripId, categoryRaw: category.rawValue, title: fields.title,
///     startsAt: fields.startsAt, endsAt: fields.endsAt, tz: fields.tz,
///     locationName: fields.locationName, locationLat: fields.locationLat, locationLng: fields.locationLng,
///     confirmation: fields.confirmation, notes: nil, detailsJSON: "{}",
///     statusRaw: (isSuggesting ? ItemStatus.suggested : ItemStatus.confirmed).rawValue, createdBy: creatorId,
///     createdAt: now, updatedAt: now, updatedBy: nil
/// )
/// ```
///
/// The regression this guards against: a future edit that "simplifies" the
/// ternary away (e.g. always `.confirmed`) would compile fine and silently
/// let a viewer's suggestion straight past `ImportReviewBanner`/
/// `SuggestedItemsSheet`'s review queue and onto the trusted itinerary —
/// exactly the write a viewer's RLS grant does NOT cover.
final class AddItemSheetSuggestStampingTests: XCTestCase {
    func testSuggestModeCreateStampsSuggestedStatusManualSourceAndSelfAsCreator() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let tripId = UUID()
        let creatorId = UUID()
        let now = Date()
        let isSuggesting = true
        let item = ItineraryItem(
            id: UUID(), tripId: tripId, categoryRaw: ItemCategory.activity.rawValue, title: "Sunset kayak tour",
            startsAt: now, endsAt: nil, tz: "UTC", locationName: "", locationLat: nil, locationLng: nil,
            confirmation: nil, notes: nil, detailsJSON: "{}",
            statusRaw: (isSuggesting ? ItemStatus.suggested : ItemStatus.confirmed).rawValue, createdBy: creatorId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        context.insert(item)
        try context.save()

        // Re-fetch through a FRESH context on the same in-memory container —
        // proves this actually persisted, not just an in-flight object graph
        // the insert still happens to hold a reference to.
        let readContext = ModelContext(container)
        let fetched = try XCTUnwrap(try readContext.fetch(FetchDescriptor<ItineraryItem>()).first)
        XCTAssertEqual(fetched.status, .suggested, "a viewer's suggestion must land as .suggested, or it skips the review pipeline")
        XCTAssertEqual(fetched.source, .manual, "a viewer typing their own plan is a manual source, same as any other direct add")
        XCTAssertEqual(fetched.createdBy, creatorId, "created_by must be the suggesting viewer themselves, per the RLS grant")
        XCTAssertEqual(fetched.tripId, tripId)
    }

    /// Contrast case: the SAME construction with `isSuggesting = false`
    /// (every other `AddItemSheet` create-mode call site) must still land
    /// `.confirmed` — proves the ternary, not a flipped default, is what's
    /// under test above.
    func testNonSuggestModeCreateStillStampsConfirmedStatus() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let creatorId = UUID()
        let now = Date()
        let isSuggesting = false
        let item = ItineraryItem(
            id: UUID(), tripId: UUID(), categoryRaw: ItemCategory.activity.rawValue, title: "Museum visit",
            startsAt: now, endsAt: nil, tz: "UTC", locationName: "", locationLat: nil, locationLng: nil,
            confirmation: nil, notes: nil, detailsJSON: "{}",
            statusRaw: (isSuggesting ? ItemStatus.suggested : ItemStatus.confirmed).rawValue, createdBy: creatorId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        context.insert(item)
        try context.save()

        let readContext = ModelContext(container)
        let fetched = try XCTUnwrap(try readContext.fetch(FetchDescriptor<ItineraryItem>()).first)
        XCTAssertEqual(fetched.status, .confirmed)
    }
}
