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
}
