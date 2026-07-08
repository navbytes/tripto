import Foundation

/// User-facing actions on a permanently-failed sync (FIX #1: `SyncStore
/// .markPermanentFailure`'s `SyncIssue` rows used to be recorded and never
/// surfaced — this is what lets `SyncIssueBanner`/`SyncIssuesSheet` actually
/// do something about one). Every entry point delegates the SwiftData work
/// to `store`, then republishes `SyncStatus` — the same "delegate, then
/// `refreshStatusCounts()`" shape every other mutation in this file's
/// siblings follows.
extension SyncEngine {
    /// Drops one issue. The row itself isn't touched here — once the
    /// dropped op no longer protects it, the *next* pull for that scope
    /// naturally reverts it to server truth (`SyncStore+Apply.swift`'s
    /// upsert-by-id + `SyncReconcile.idsToDelete`: a row absent from
    /// `allPendingRowIds()` either gets overwritten by the server's version
    /// or deleted if the server never had it). `pullHome()` below gives the
    /// two home-scope retriable tables (`.trips`, `.tripProfiles`) that
    /// refresh right away rather than waiting for this trip's own next
    /// pull; it's skipped while offline like every other pull entry point.
    func dismissIssue(id: UUID) async {
        try? await store.dismissIssue(id: id)
        await refreshStatusCounts()
        guard !isEffectivelyOffline else { return }
        await pullHome()
    }

    /// Same as `dismissIssue(id:)`, for every outstanding issue at once
    /// ("Dismiss all" in `SyncIssuesSheet`).
    func dismissAllIssues() async {
        try? await store.dismissAllIssues()
        await refreshStatusCounts()
        guard !isEffectivelyOffline else { return }
        await pullHome()
    }

    /// "Try again" on a `retriable` issue: rebuilds an upsert from the row's
    /// current local state and re-queues it (a no-op if the row's table is
    /// `.itemAssignees` or the row has since vanished locally — see
    /// `SyncStore.reenqueueUpsertFromLocalRow`'s doc comment), then drops
    /// the issue either way and kicks the push loop so the retry is sent
    /// immediately rather than waiting for an unrelated future mutation.
    func retryIssue(id: UUID, rowId: UUID, tableRaw: String) async {
        if let table = SyncTable(rawValue: tableRaw) {
            _ = try? await store.reenqueueUpsertFromLocalRow(rowId: rowId, table: table)
        }
        try? await store.dismissIssue(id: id)
        await refreshStatusCounts()
        schedulePush()
    }
}
