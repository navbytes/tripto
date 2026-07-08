import XCTest
@testable import Tripto

/// Category-aware family tags (persona dry-run: "Kids' menu on a flight is
/// nonsense"). Each `ItemTag` is offered only for the categories it makes
/// sense on.
final class TagCategoryTests: XCTestCase {
    func testKidsMenuIsFoodOnly() {
        XCTAssertTrue(ItemTag.allowed(for: .food).contains(.kidsMenu))
        XCTAssertFalse(ItemTag.allowed(for: .flight).contains(.kidsMenu))
        XCTAssertFalse(ItemTag.allowed(for: .activity).contains(.kidsMenu))
        XCTAssertFalse(ItemTag.allowed(for: .hotel).contains(.kidsMenu))
        XCTAssertFalse(ItemTag.allowed(for: .transport).contains(.kidsMenu))
    }

    func testHotelStayOffersNoFamilyTags() {
        XCTAssertTrue(ItemTag.allowed(for: .hotel).isEmpty)
    }

    func testActivityOffersNapAndStrollerButNotKidsMenu() {
        let tags = ItemTag.allowed(for: .activity)
        XCTAssertTrue(tags.contains(.nap))
        XCTAssertTrue(tags.contains(.strollerOk))
        XCTAssertFalse(tags.contains(.kidsMenu))
    }

    func testFlightOffersNapOnly() {
        XCTAssertEqual(ItemTag.allowed(for: .flight), [.nap])
    }

    func testAllowedPreservesAllCasesOrder() {
        // Food allows all three, which must return in declaration order.
        XCTAssertEqual(ItemTag.allowed(for: .food), [.nap, .strollerOk, .kidsMenu])
    }
}
