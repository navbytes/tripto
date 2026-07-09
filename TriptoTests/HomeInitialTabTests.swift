import XCTest
@testable import Tripto

/// `HomeInitialTab.resolve` (UX audit finding 1) — the regression net for a
/// returning all-completed-trips user landing on an empty "Upcoming" tab.
final class HomeInitialTabTests: XCTestCase {
    func testNoUpcomingWithPastRedirectsToPast() {
        let result = HomeInitialTab.resolve(hasUpcoming: false, hasPast: true)
        XCTAssertEqual(result, "Past")
    }

    func testUpcomingAndPastStaysOnUpcoming() {
        let result = HomeInitialTab.resolve(hasUpcoming: true, hasPast: true)
        XCTAssertEqual(result, "Upcoming")
    }

    func testUpcomingOnlyStaysOnUpcoming() {
        let result = HomeInitialTab.resolve(hasUpcoming: true, hasPast: false)
        XCTAssertEqual(result, "Upcoming")
    }

    func testAllEmptyDefaultsToUpcoming() {
        // The all-empty case is handled upstream by the empty-state branch,
        // but the helper must still default safely if ever called with it.
        let result = HomeInitialTab.resolve(hasUpcoming: false, hasPast: false)
        XCTAssertEqual(result, "Upcoming")
    }
}
