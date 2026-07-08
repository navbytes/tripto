import Foundation

/// Main-actor observable surface for `SyncEngine` — SYNC_DESIGN.md
/// "Status surface." Views read this directly (e.g. the offline banner,
/// a card's "waiting to sync" chip); `SyncEngine` is the only writer, and
/// always hops to the main actor to do so since this class is itself
/// `@MainActor`-isolated.
@Observable
@MainActor
final class SyncStatus {
    private(set) var isOffline: Bool = false
    private(set) var pendingCount: Int = 0
    private(set) var pendingRowIds: Set<UUID> = []
    private(set) var lastSyncedAt: Date?
    /// Permanently-failed outbox ops (`SyncEngine+Push.PushOutcome.permanent`)
    /// the user hasn't dismissed yet — `SyncIssueBanner`/`SyncIssuesSheet`'s
    /// data source. Newest-first, matching `SyncStore.allIssues()`'s sort.
    private(set) var syncIssues: [SyncIssueSnapshot] = []
    /// True once `pullHome()` has completed an attempt (success or failure)
    /// this session — `HomeView`'s signal to show a neutral "Checking for
    /// your trips…" placeholder instead of the "Plan your first trip" empty
    /// state while a genuinely-empty account can't yet be told apart from
    /// "haven't heard from the server yet" (finding 2).
    private(set) var hasCompletedInitialHomePull = false
    /// True after a `pullHome()` attempt fails (network/server error), false
    /// after the next one succeeds — `HomeView`'s signal to show the honest
    /// "couldn't check for trips" placeholder (with a retry) instead of
    /// misreading the failure as a genuinely-empty account (finding 1).
    private(set) var lastHomePullFailed = false
    /// Per-trip mirror of `hasCompletedInitialHomePull` (finding 2):
    /// `TripId`s for which `pullTrip(_:)` has completed an attempt (success
    /// or failure) this session — `TripView`'s signal to show a neutral
    /// "Checking…" placeholder instead of a tab's real empty state while a
    /// freshly-claimed (or just-opened) trip's first pull is still in
    /// flight.
    private(set) var completedInitialTripPulls: Set<UUID> = []

    func setOffline(_ offline: Bool) {
        isOffline = offline
    }

    func setPending(count: Int, rowIds: Set<UUID>) {
        pendingCount = count
        pendingRowIds = rowIds
    }

    func markSynced(at date: Date = .now) {
        lastSyncedAt = date
    }

    func setIssues(_ issues: [SyncIssueSnapshot]) {
        syncIssues = issues
    }

    func markInitialHomePullCompleted() {
        hasCompletedInitialHomePull = true
    }

    func setHomePullFailed(_ failed: Bool) {
        lastHomePullFailed = failed
    }

    func markInitialTripPullCompleted(_ tripId: UUID) {
        completedInitialTripPulls.insert(tripId)
    }

    /// Sign-out wipe: the next sign-in (potentially a different account)
    /// re-enters the first-pull loading state instead of reading an empty
    /// wiped cache as "you have zero trips," and doesn't carry a stale
    /// failure flag (or a previous account's completed-trip set) into the
    /// next account's session.
    func resetInitialPullState() {
        hasCompletedInitialHomePull = false
        lastHomePullFailed = false
        completedInitialTripPulls = []
    }
}
