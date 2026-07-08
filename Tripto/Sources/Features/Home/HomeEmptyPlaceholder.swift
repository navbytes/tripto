import Foundation

/// Pure decision table for which placeholder `HomeView` shows while
/// `trips` is empty (UX audit finding 1). No SwiftUI import on purpose —
/// `HomeView` owns the actual views; this only owns the branching logic, so
/// it's directly unit-testable without standing up a view hierarchy.
enum HomeEmptyPlaceholder {
    /// Invite claim in flight — highest priority; a joining spinner takes
    /// precedence over any pull-related state (finding 6).
    case joining
    /// First mount this session, online, pull hasn't completed yet.
    case initialLoad
    /// Offline, and either the first pull never completed or the last
    /// attempt failed — offline copy outranks retry copy here since
    /// `pullHome()` no-ops while offline, so a "Try again" button would be
    /// a dead end.
    case offlineFirstLoad
    /// Online, and the last `pullHome()` attempt failed — the account may
    /// or may not actually be empty; the honest answer is "couldn't check,"
    /// not "plan your first trip" (finding 1's headline case).
    case pullFailed
    /// Pull succeeded and came back with zero trips.
    case empty

    static func resolve(
        isJoiningTrip: Bool,
        hasCompletedInitialHomePull: Bool,
        lastHomePullFailed: Bool,
        isOffline: Bool
    ) -> Self {
        if isJoiningTrip {
            return .joining
        }
        if !hasCompletedInitialHomePull && !isOffline {
            return .initialLoad
        }
        if isOffline && (!hasCompletedInitialHomePull || lastHomePullFailed) {
            return .offlineFirstLoad
        }
        if lastHomePullFailed {
            return .pullFailed
        }
        return .empty
    }
}
