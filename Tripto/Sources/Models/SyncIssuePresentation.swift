import Foundation

/// Pure presentation mapping for a `SyncIssueSnapshot` (FIX #1) — no
/// SwiftUI, so directly testable (`SyncIssuePresentationTests`).
/// `SyncIssueBanner`/`SyncIssuesSheet` are the only production callers.
enum SyncIssuePresentation {
    /// A human name for the table a dropped op belonged to, for a
    /// "{title} couldn't be saved" heading. Defensive like every other
    /// raw-string-to-enum lookup in this app (`Enums.swift`'s doc
    /// comment) — an unrecognized/composite-key table falls back to the
    /// generic "change" rather than showing nothing.
    static func title(forTable table: SyncTable?) -> String {
        switch table {
        case .itineraryItems: return "itinerary item"
        case .trips: return "trip"
        case .packingItems: return "packing item"
        case .tripProfiles: return "traveler"
        default: return "change"
        }
    }

    /// Body copy — split on whether the same write could plausibly succeed
    /// if tried again (`SyncEngine+Push.PushOutcome.permanent(retriable:)`).
    static func message(retriable: Bool) -> String {
        retriable
            ? "Couldn\u{2019}t reach the server after several tries."
            : "This change couldn\u{2019}t be saved \u{2014} you may not have permission, or it conflicts with someone else\u{2019}s edit."
    }

    /// `SyncIssueBanner`'s summary line, correctly pluralized.
    static func bannerText(count: Int) -> String {
        count == 1 ? "Couldn\u{2019}t save 1 change" : "Couldn\u{2019}t save \(count) changes"
    }
}
