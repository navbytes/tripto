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

    /// `CaseIterable` sweep, independent of the fixed list above: the
    /// exhaustive `switch` in `addSheetVerbLabel` already forces the
    /// compiler to catch an unmapped case, but it wouldn't catch a *lazy*
    /// mapping — e.g. a copy-pasted `case .newCategory: "Flight"` that still
    /// compiles. This pins the mapping as a true bijection: every case
    /// present, none blank, and no two categories sharing one label.
    func testVerbLabelIsABijectionOverEveryItemCategoryCase() {
        let labels = ItemCategory.allCases.map(\.addSheetVerbLabel)
        XCTAssertEqual(labels.count, ItemCategory.allCases.count, "every case must produce exactly one label")
        XCTAssertTrue(labels.allSatisfy { !$0.isEmpty }, "no category should get a blank verb label")
        XCTAssertEqual(
            Set(labels).count, ItemCategory.allCases.count,
            "verb labels must be a bijection \u{2014} no two categories may share one"
        )
    }
}
