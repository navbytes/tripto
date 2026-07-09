import Foundation

/// Pure decision helper for whether a pull-to-refresh gesture that just
/// finished should surface a toast (UX audit finding 1's refresh-scoped
/// gap: a manual pull-to-refresh that fails leaves no feedback — the list
/// just silently doesn't update). No SwiftUI import on purpose — `HomeView`
/// owns the actual toast; this only owns the branching logic, so it's
/// directly unit-testable without standing up a view hierarchy (mirrors
/// `HomeEmptyPlaceholder`'s house pattern).
enum HomeRefreshFeedback {
    /// - `isOffline` is excluded: `pullHome()` no-ops while offline without
    ///   touching `lastHomePullFailed`, and `SyncBanner` already owns
    ///   communicating the offline state — toasting on top would double-signal.
    /// - `hasTrips` is excluded when false: an empty-account pull failure is
    ///   already owned by `HomeEmptyPlaceholder`'s `pullFailedState`, which
    ///   replaces the whole screen rather than layering a toast over it.
    static func shouldToastAfterRefresh(
        lastHomePullFailed: Bool,
        isOffline: Bool,
        hasTrips: Bool
    ) -> Bool {
        lastHomePullFailed && !isOffline && hasTrips
    }

    /// Whether `pullFailedState`'s "Try again" button should surface an
    /// inline note after a repeat failure (UX audit finding 1 — silently
    /// re-disabling the button with no feedback reads as broken, not
    /// retrying). `isOffline` is excluded for the same reason
    /// `shouldToastAfterRefresh` excludes it, but by a different path here:
    /// `HomeEmptyPlaceholder.resolve` already flips the *whole screen* to
    /// `offlineFirstLoadState` once offline+failed, so this helper would
    /// never even be consulted in that case — the guard is kept anyway so
    /// the two helpers stay symmetric and safe to call defensively.
    static func shouldNoteRetryFailure(lastHomePullFailed: Bool, isOffline: Bool) -> Bool {
        lastHomePullFailed && !isOffline
    }
}
