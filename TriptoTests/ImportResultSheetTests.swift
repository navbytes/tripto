import XCTest
@testable import Tripto

/// P6.1 (docs/UX_REDESIGN_ROADMAP.md): `ImportResultSheet`'s pure text
/// helpers — same "test the pure static, not the view" convention
/// `SettingsExportCountsTests` already uses for this screen's other
/// count-driven copy.
final class ImportResultSheetTests: XCTestCase {
    // MARK: - subtitleText

    func testSubtitleForASingleTrip() {
        XCTAssertEqual(ImportResultSheet.subtitleText(tripsImported: 1), "Your trip is ready to explore.")
    }

    func testSubtitleForMultipleTrips() {
        XCTAssertEqual(ImportResultSheet.subtitleText(tripsImported: 20), "Your trips are ready to explore.")
    }

    /// The degraded small-import case at its extreme — every trip in the
    /// archive was skipped, nothing new imported. Must read as honest, not
    /// broken ("your 0 trips are ready" would).
    func testSubtitleForZeroTripsDoesNotClaimSomethingWasImported() {
        XCTAssertTrue(ImportResultSheet.subtitleText(tripsImported: 0).localizedCaseInsensitiveContains("nothing"))
    }

    // MARK: - primaryActionText

    func testPrimaryActionForASingleTrip() {
        XCTAssertEqual(ImportResultSheet.primaryActionText(tripsImported: 1), "See your 1 trip")
    }

    func testPrimaryActionForMultipleTrips() {
        XCTAssertEqual(ImportResultSheet.primaryActionText(tripsImported: 20), "See your 20 trips")
    }

    /// Degraded small-import case (this phase's own acceptance bullet): a
    /// report with zero imported trips must not offer to "See your 0
    /// trips" — that reads as broken, not helpful.
    func testPrimaryActionForZeroTripsDegradesToDone() {
        XCTAssertEqual(ImportResultSheet.primaryActionText(tripsImported: 0), "Done")
    }

    // MARK: - sentenceCased (moved here from the deleted `ArchiveImportReportSheet`)

    func testSentenceCasedOnlyRaisesTheFirstLetter() {
        XCTAssertEqual(ImportResultSheet.sentenceCased("missing id"), "Missing id")
        XCTAssertEqual(ImportResultSheet.sentenceCased("no start date"), "No start date")
    }

    func testSentenceCasedOnEmptyStringIsANoOp() {
        XCTAssertEqual(ImportResultSheet.sentenceCased(""), "")
    }
}
