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

    // MARK: - All-skipped import (a real `TripArchiveImportReport`, not bare ints)

    /// The brief's "all-skipped import": every trip in the archive was
    /// itself skipped (cancelled/already-imported/no-start-date/etc.), so
    /// `tripsImported == 0` but there are real skip rows to show — distinct
    /// from a report that's simply empty. Exercises the mapping off an
    /// actual report value (as `SettingsView` builds it), not isolated ints.
    func testAllSkippedImportReportMapsToAnHonestSubtitleAndADoneButton() {
        let report = TripArchiveImportReport(
            tripsImported: 0, itemsImported: 0, profilesImported: 0,
            tripSkips: [
                .init(tripId: "1", title: "Bangkok", reason: .alreadyImported, existingLocalTripId: UUID()),
                .init(tripId: "2", title: "Parents\u{2019} visit to Hong Kong", reason: .cancelled),
                .init(tripId: "3", title: "", reason: .noStartDate)
            ],
            itemSkips: [
                .init(tripId: "1", tripTitle: "Bangkok", itemId: "i1", itemLabel: "Flight 6E204", reason: .noStartTime)
            ]
        )

        XCTAssertTrue(ImportResultSheet.subtitleText(tripsImported: report.tripsImported).localizedCaseInsensitiveContains("nothing"))
        XCTAssertEqual(ImportResultSheet.primaryActionText(tripsImported: report.tripsImported), "Done")
        XCTAssertFalse(report.isFullSuccess, "an all-skipped import is never a full success — the skip section must render")
        XCTAssertEqual(report.tripSkips.count + report.itemSkips.count, 4, "every skip row must be counted, trip and item alike")
    }
}
