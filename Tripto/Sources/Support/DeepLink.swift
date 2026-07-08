import Foundation

/// The two public URL shapes this app cares about — both served by
/// `web/share-worker` (a separate repo surface this app never touches; see
/// that worker's README for the exact token patterns it validates):
///
/// - `https://tripto.navbytes.io/t/<token>` — the public, no-app, read-only
///   itinerary page (BUILD_PLAN.md §5.2). **Web-only** — opening it must
///   never be mistaken for an invite.
/// - `https://tripto.navbytes.io/join/<token>` / `tripto://join/<token>` —
///   the role-carrying invite link (RESEARCH_FINDINGS.md amendment #3),
///   which this app claims via `claim_invite(token)`.
///
/// This type both *builds* the links `ShareTripView` displays/shares and
/// *parses* the ones `.onOpenURL` receives, so the host/token shape lives
/// in exactly one place.
enum DeepLink {
    static let host = "tripto.navbytes.io"
    static let scheme = "tripto"

    // MARK: - Building (ShareTripView)

    /// `https://tripto.navbytes.io/t/<token>` — the anyone-can-view link.
    static func shareURL(token: String) -> URL {
        URL(string: "https://\(host)/t/\(token)")!
    }

    /// `https://tripto.navbytes.io/join/<token>` — always the `https` form
    /// for outbound sharing (works for a recipient without the app yet, via
    /// the web `/join` interstitial), even though the app itself also
    /// handles the bare `tripto://join/<token>` scheme below.
    static func inviteURL(token: String) -> URL {
        URL(string: "https://\(host)/join/\(token)")!
    }

    // MARK: - Parsing (.onOpenURL)

    /// Extracts the invite token from either the custom-scheme or
    /// universal-link shape of `/join/<token>`. Returns `nil` for anything
    /// else — including malformed paths and, deliberately, the *share*
    /// path (`/t/<token>`), which is web-only and must never be treated as
    /// an invite.
    static func inviteToken(from url: URL) -> String? {
        guard let urlScheme = url.scheme?.lowercased() else { return nil }
        let segments: [String]

        switch urlScheme {
        case scheme:
            // "tripto://join/<token>" — for a custom scheme, the part
            // right after "://" up to the next "/" parses as the URL's
            // *host* ("join"), not a path segment; the token is the path.
            guard url.host?.lowercased() == "join" else { return nil }
            segments = url.pathComponents.filter { $0 != "/" }
        case "https", "http":
            guard url.host?.lowercased() == host else { return nil }
            var components = url.pathComponents.filter { $0 != "/" }
            guard !components.isEmpty, components.removeFirst().lowercased() == "join" else { return nil }
            segments = components
        default:
            return nil
        }

        // A token never contains a "/", so a well-formed invite link has
        // exactly one segment after "join" — anything else (no token, or
        // extra trailing segments) isn't a shape this app recognizes.
        guard segments.count == 1, let token = segments.first, !token.isEmpty else { return nil }
        return token
    }
}
