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
}
