import SwiftData
import XCTest
@testable import Tripto

/// BRIEF (app-intents deepening): `ConfirmationCodeIntent`'s one SwiftData
/// touch (`ConfirmationCodeLookup`) and its dialog builder
/// (`ConfirmationCodeDialog`) — same "`SyncStore`-level, no `SyncEngine`/
/// network" in-memory-container shape as `ItemAssigneeSyncTests`.
final class ConfirmationCodeIntentSupportTests: XCTestCase {
    private func makeContext() -> ModelContext {
        ModelContext(AppSchema.makeContainer(inMemory: true))
    }

    // MARK: - ConfirmationCodeLookup — found / absent / nil-details

    func testReturnsTheCodeWhenTheItemHasOne() throws {
        let context = makeContext()
        let item = TestFixtures.makeItineraryItem(startsAt: .now, confirmation: "QK7P2M")
        context.insert(item)
        try context.save()

        XCTAssertEqual(ConfirmationCodeLookup.code(forItemId: item.id, in: context), "QK7P2M")
    }

    /// Absent: no item with this id exists in the store at all — e.g. a
    /// stale donated shortcut referencing a since-deleted booking.
    func testReturnsNilWhenNoItemMatchesTheId() {
        let context = makeContext()
        XCTAssertNil(ConfirmationCodeLookup.code(forItemId: UUID(), in: context))
    }

    /// nil-details: the item exists but never had a code saved.
    func testReturnsNilWhenConfirmationIsNil() throws {
        let context = makeContext()
        let item = TestFixtures.makeItineraryItem(startsAt: .now, confirmation: nil)
        context.insert(item)
        try context.save()

        XCTAssertNil(ConfirmationCodeLookup.code(forItemId: item.id, in: context))
    }

    /// nil-details, whitespace variant: a blank string must read the same
    /// as never having set one, not as a real (empty) code.
    func testReturnsNilWhenConfirmationIsBlank() throws {
        let context = makeContext()
        let item = TestFixtures.makeItineraryItem(startsAt: .now, confirmation: "   ")
        context.insert(item)
        try context.save()

        XCTAssertNil(ConfirmationCodeLookup.code(forItemId: item.id, in: context))
    }

    // MARK: - ConfirmationCodeDialog

    func testBuildReadsTheCodeAloudWhenPresent() {
        XCTAssertEqual(
            ConfirmationCodeDialog.build(title: "TAP TP1234", code: "QK7P2M"),
            "TAP TP1234\u{2019}s confirmation code is QK7P2M."
        )
    }

    func testBuildNamesTheBookingWhenNoCodeIsSaved() {
        XCTAssertEqual(ConfirmationCodeDialog.build(title: "TAP TP1234", code: nil), "No code saved for TAP TP1234.")
    }
}
