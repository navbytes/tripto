import XCTest
@testable import Tripto

/// Pure presentation mapping for a permanently-failed sync (`SyncIssueSnapshot`)
/// — no SwiftUI, so directly testable. `SyncIssueBanner`/`SyncIssuesSheet` are
/// the only production callers.
final class SyncIssuePresentationTests: XCTestCase {
    // MARK: - bannerText pluralization

    func testBannerTextIsSingularAtOne() {
        XCTAssertEqual(SyncIssuePresentation.bannerText(count: 1), "Couldn\u{2019}t save 1 change")
    }

    func testBannerTextIsPluralAtN() {
        XCTAssertEqual(SyncIssuePresentation.bannerText(count: 3), "Couldn\u{2019}t save 3 changes")
    }

    func testBannerTextIsPluralAtZero() {
        // Not a state the banner is ever shown in (it's gated on a non-empty
        // list), but the pluralization rule itself shouldn't special-case 0.
        XCTAssertEqual(SyncIssuePresentation.bannerText(count: 0), "Couldn\u{2019}t save 0 changes")
    }

    // MARK: - message(retriable:)

    func testMessageForRetriableIssue() {
        XCTAssertEqual(
            SyncIssuePresentation.message(retriable: true),
            "Couldn\u{2019}t reach the server after several tries."
        )
    }

    func testMessageForNonRetriableIssue() {
        XCTAssertEqual(
            SyncIssuePresentation.message(retriable: false),
            "This change couldn\u{2019}t be saved \u{2014} you may not have permission, or it conflicts with someone else\u{2019}s edit."
        )
    }

    // MARK: - title(forTable:)

    func testTableTitles() {
        XCTAssertEqual(SyncIssuePresentation.title(forTable: .itineraryItems), "itinerary item")
        XCTAssertEqual(SyncIssuePresentation.title(forTable: .trips), "trip")
        XCTAssertEqual(SyncIssuePresentation.title(forTable: .packingItems), "packing item")
        XCTAssertEqual(SyncIssuePresentation.title(forTable: .tripProfiles), "traveler")
    }

    func testTableTitleFallsBackToChangeForUnlistedOrUnknownTables() {
        XCTAssertEqual(SyncIssuePresentation.title(forTable: .itemAssignees), "change")
        XCTAssertEqual(SyncIssuePresentation.title(forTable: .profiles), "change")
        XCTAssertEqual(SyncIssuePresentation.title(forTable: nil), "change")
    }
}
