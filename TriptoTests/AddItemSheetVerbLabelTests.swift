import XCTest
@testable import Tripto

/// Phase 3 (docs/UX_REDESIGN_ROADMAP.md P3.1): the add-item sheet's type
/// tiles read as verbs ("what am I adding"), not `ItemCategory.displayName`'s
/// nouns — pinned separately from `displayName` since that property is
/// shared with `BookingsTabView`/`TimelineCardRow`/`SuggestedItemsSheet` and
/// must stay untouched by this milestone.
final class AddItemSheetVerbLabelTests: XCTestCase {
    func testEveryCategoryGetsItsOwnVerbLabel() {
        XCTAssertEqual(ItemCategory.flight.addSheetVerbLabel, "Flight")
        XCTAssertEqual(ItemCategory.hotel.addSheetVerbLabel, "Stay")
        XCTAssertEqual(ItemCategory.activity.addSheetVerbLabel, "Do")
        XCTAssertEqual(ItemCategory.food.addSheetVerbLabel, "Eat")
        XCTAssertEqual(ItemCategory.transport.addSheetVerbLabel, "Ride")
    }

    /// The three categories whose noun wasn't already a verb ("Activity"/
    /// "Food"/"Transport") must actually get a *different* tile label —
    /// flight/hotel's nouns already doubled as verbs, so those two are
    /// allowed to match `displayName`.
    func testVerbLabelDiffersFromDisplayNameWhereTheNounWasNotAlreadyAVerb() {
        XCTAssertNotEqual(ItemCategory.activity.addSheetVerbLabel, ItemCategory.activity.displayName)
        XCTAssertNotEqual(ItemCategory.food.addSheetVerbLabel, ItemCategory.food.displayName)
        XCTAssertNotEqual(ItemCategory.transport.addSheetVerbLabel, ItemCategory.transport.displayName)
    }

    /// `displayName` itself must stay exactly as it was — it feeds
    /// `BookingsTabView`'s section headers and `TimelineCardRow`/
    /// `SuggestedItemsSheet`'s VoiceOver category word, none of which this
    /// milestone's brief touches.
    func testDisplayNameIsUnchangedByTheNewVerbLabels() {
        XCTAssertEqual(ItemCategory.flight.displayName, "Flight")
        XCTAssertEqual(ItemCategory.hotel.displayName, "Stay")
        XCTAssertEqual(ItemCategory.activity.displayName, "Activity")
        XCTAssertEqual(ItemCategory.food.displayName, "Food")
        XCTAssertEqual(ItemCategory.transport.displayName, "Transport")
    }
}
