import Foundation

/// Exponential backoff with jitter, capped at 60s — the one retry-delay
/// shape every "this failed, try again later, but don't hammer it" path in
/// the sync engine uses. Originally `SyncEngine+Push.swift`'s push retry;
/// `SyncEngine+Realtime.swift`'s subscribe retry reuses it too. A free pure
/// function (no `Task`/actor involved) so it's testable as plain math.
enum SyncBackoff {
    /// `attemptsSoFar` counts attempts already made (same convention as
    /// `PushErrorClassifier.classify(attemptsSoFar:maxAttempts:)`) — the
    /// delay returned is how long to wait before the *next* one. Jitter is
    /// `0...1` seconds on top of the exponential term.
    static func delay(attemptsSoFar: Int, cap: TimeInterval = 60) -> TimeInterval {
        let exponent = min(attemptsSoFar, 6)
        return min(pow(2.0, Double(exponent)) + Double.random(in: 0...1), cap)
    }
}
