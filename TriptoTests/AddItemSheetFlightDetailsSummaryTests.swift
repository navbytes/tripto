import XCTest
@testable import Tripto

/// Phase 3 (docs/UX_REDESIGN_ROADMAP.md P3.3): the seat/terminal/gate/
/// confirmation `DisclosureGroup`'s one-line collapsed summary.
final class AddItemSheetFlightDetailsSummaryTests: XCTestCase {
    func testAllFourFieldsJoinInOrder() {
        XCTAssertEqual(
            AddItemSheet.flightDetailsSummary(seat: "14C", terminal: "1", gate: "22", confirmation: "QK7P2M"),
            "14C \u{00B7} 1 \u{00B7} 22 \u{00B7} QK7P2M"
        )
    }

    /// The design mockup's own example (design/ux-redesign-2026-07/
    /// tripto-redesign.html) leaves gate blank — it's dropped entirely, not
    /// rendered as its own em-dash placeholder mid-string.
    func testAnEmptyFieldIsOmittedNotPlaceholdered() {
        XCTAssertEqual(
            AddItemSheet.flightDetailsSummary(seat: "14C", terminal: "1", gate: "", confirmation: "QK7P2M"),
            "14C \u{00B7} 1 \u{00B7} QK7P2M"
        )
    }

    func testWhitespaceOnlyFieldCountsAsEmpty() {
        XCTAssertEqual(AddItemSheet.flightDetailsSummary(seat: "   ", terminal: "1", gate: "", confirmation: ""), "1")
    }

    /// Nothing set at all — a single em-dash placeholder for the whole
    /// summary, not four separate ones.
    func testEverythingEmptyShowsASingleEmDash() {
        XCTAssertEqual(AddItemSheet.flightDetailsSummary(seat: "", terminal: "", gate: "", confirmation: ""), "\u{2014}")
    }

    func testASingleFieldRendersAlone() {
        XCTAssertEqual(AddItemSheet.flightDetailsSummary(seat: "", terminal: "", gate: "", confirmation: "QK7P2M"), "QK7P2M")
    }
}
