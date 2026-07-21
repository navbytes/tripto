import XCTest
@testable import Tripto

/// BRIEF (app-intents deepening): `AddToPackingIntent`'s label validation
/// and every dialog string it can answer with, as plain `String -> String`
/// functions — same "no `AppIntent` machinery" discipline as `NextUpDialogTests`.
final class AddToPackingDialogTests: XCTestCase {
    // MARK: - validatedLabel (same trim/empty rule as `PackingItem.insert`)

    func testValidatedLabelTrimsSurroundingWhitespace() {
        XCTAssertEqual(AddToPackingDialog.validatedLabel("  sunscreen  "), "sunscreen")
    }

    func testValidatedLabelReturnsNilForBlankInput() {
        XCTAssertNil(AddToPackingDialog.validatedLabel("   "))
    }

    func testValidatedLabelReturnsNilForEmptyInput() {
        XCTAssertNil(AddToPackingDialog.validatedLabel(""))
    }

    func testValidatedLabelPreservesInternalWhitespace() {
        XCTAssertEqual(AddToPackingDialog.validatedLabel("  sun screen  "), "sun screen")
    }

    // MARK: - confirmation

    func testConfirmationNamesTheItemAndTheTrip() {
        XCTAssertEqual(
            AddToPackingDialog.confirmation(item: "sunscreen", tripTitle: "Lisbon"),
            "Added sunscreen to Lisbon\u{2019}s packing list."
        )
    }
}
