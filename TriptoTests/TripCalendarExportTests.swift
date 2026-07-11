import XCTest
@testable import Tripto

/// E1 "Add Trip to Calendar" (docs/BACKLOG.md §E1) — `TripCalendarExport` is
/// deliberately Foundation-only (see its own doc comment), so eligibility,
/// idempotency, and the summary toast's count math are all testable with no
/// calendar permission and no `EKEventStore` involved; `TripView.swift` is
/// the only place that actually touches EventKit for the batch export.
final class TripCalendarExportTests: XCTestCase {
    // MARK: - Eligibility (confirmed-only, has a start time)

    func testConfirmedItemWithAStartTimeIsEligible() {
        XCTAssertTrue(TripCalendarExport.isEligible(status: .confirmed, startsAt: .now))
    }

    func testSuggestedItemIsNeverEligibleEvenWithAStartTime() {
        XCTAssertFalse(TripCalendarExport.isEligible(status: .suggested, startsAt: .now))
    }

    /// `startsAt` is non-optional on the real `ItineraryItem` model (see
    /// `TripCalendarExport.isEligible`'s doc comment) — this pins the
    /// predicate's contract directly since real data can never exercise it.
    func testConfirmedItemWithNoStartTimeIsNotEligible() {
        XCTAssertFalse(TripCalendarExport.isEligible(status: .confirmed, startsAt: nil))
    }

    func testEligibleItemsKeepsOnlyConfirmedFromAMixedList() {
        let confirmed = TestFixtures.makeItineraryItem(startsAt: .now, tz: "UTC", status: .confirmed)
        let suggested = TestFixtures.makeItineraryItem(startsAt: .now, tz: "UTC", status: .suggested)

        let eligible = TripCalendarExport.eligibleItems([confirmed, suggested])

        XCTAssertEqual(eligible.map(\.id), [confirmed.id])
    }

    func testEligibleItemsOnAnAllSuggestedTripIsEmpty() {
        let suggested = TestFixtures.makeItineraryItem(startsAt: .now, tz: "UTC", status: .suggested)
        XCTAssertTrue(TripCalendarExport.eligibleItems([suggested]).isEmpty)
    }

    // MARK: - Idempotency tag + skip decision (§3: re-running must not duplicate)

    func testExportTagURLIsTheItemDeepLinkFallbackShape() {
        let id = UUID()
        // DeepLink.swift has no item-level link today (only `tripto://trip/
        // <uuid>`) — this is E1's brief-noted fallback shape.
        XCTAssertEqual(TripCalendarExport.exportTagURL(itemId: id).absoluteString, "tripto://item/\(id.uuidString)")
    }

    func testShouldSkipWhenTheSameItemsTagURLIsAlreadyInTheWindow() {
        let id = UUID()
        let existing: Set<URL> = [TripCalendarExport.exportTagURL(itemId: id)]
        XCTAssertTrue(TripCalendarExport.shouldSkip(itemId: id, existingEventURLs: existing))
    }

    func testDoesNotSkipWhenTheWindowHasOnlyADifferentItemsTagURL() {
        let id = UUID()
        let otherId = UUID()
        let existing: Set<URL> = [TripCalendarExport.exportTagURL(itemId: otherId)]
        XCTAssertFalse(TripCalendarExport.shouldSkip(itemId: id, existingEventURLs: existing))
    }

    func testDoesNotSkipWhenTheWindowIsEmpty() {
        XCTAssertFalse(TripCalendarExport.shouldSkip(itemId: UUID(), existingEventURLs: []))
    }

    // MARK: - Summary toast (§4's two shapes, verbatim)

    func testSummaryMessageWithNoSkipsPluralizesLikeTheRestOfTheApp() {
        XCTAssertEqual(TripCalendarExport.Summary(added: 1, skipped: 0).message, "Added 1 event")
        XCTAssertEqual(TripCalendarExport.Summary(added: 3, skipped: 0).message, "Added 3 events")
        XCTAssertEqual(TripCalendarExport.Summary(added: 0, skipped: 0).message, "Added 0 events")
    }

    func testSummaryMessageReportsSkipsWhenAnyItemWasAlreadyThere() {
        XCTAssertEqual(TripCalendarExport.Summary(added: 2, skipped: 3).message, "Added 2, skipped 3 already there")
        // A full re-run once everything's already exported.
        XCTAssertEqual(TripCalendarExport.Summary(added: 0, skipped: 5).message, "Added 0, skipped 5 already there")
    }

    // MARK: - Summary toast with failures (review D2: failures used to be invisible)

    func testSummaryMessageReportsFailuresAlongsideAdded() {
        XCTAssertEqual(TripCalendarExport.Summary(added: 2, skipped: 0, failed: 3).message, "Added 2, 3 failed")
    }

    func testSummaryMessageReportsFailuresAndSkipsTogether() {
        XCTAssertEqual(
            TripCalendarExport.Summary(added: 1, skipped: 2, failed: 3).message,
            "Added 1, skipped 2 already there, 3 failed"
        )
    }

    /// Nothing added, nothing skipped, everything failed — the case that
    /// used to read "Added 0 events" as if the export had simply found no
    /// work to do, when it had actually failed outright.
    func testSummaryMessageWhenEveryItemFailsReadsAsAFailureNotAsSuccess() {
        XCTAssertEqual(
            TripCalendarExport.Summary(added: 0, skipped: 0, failed: 4).message,
            "Couldn\u{2019}t add events — check calendar access"
        )
    }
}
