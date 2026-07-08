import XCTest
@testable import Tripto

/// `AvatarStack.overflowCount` (UX audit finding 6): once `people.count`
/// exceeds `maxVisible`, one visible slot is traded for the "+N" overflow
/// chip so the total circle count — and the card's layout width — never
/// changes.
final class AvatarStackOverflowTests: XCTestCase {
    func testNoOverflowWhenAtOrUnderMaxVisible() {
        XCTAssertEqual(AvatarStack.overflowCount(peopleCount: 2, maxVisible: 3), 0)
        XCTAssertEqual(AvatarStack.overflowCount(peopleCount: 3, maxVisible: 3), 0)
    }

    func testOverflowTradesOneVisibleSlotForTheChip() {
        // 6 people at maxVisible 3: 2 avatars shown + "+4" hidden, not 3 + "+3".
        XCTAssertEqual(AvatarStack.overflowCount(peopleCount: 6, maxVisible: 3), 4)
    }

    func testOverflowByOne() {
        XCTAssertEqual(AvatarStack.overflowCount(peopleCount: 4, maxVisible: 3), 2)
    }
}
