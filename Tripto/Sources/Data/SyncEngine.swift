import Foundation
import Network
import Supabase
import SwiftData

/// Orchestrates SYNC_DESIGN.md end to end: enqueueing outbox ops, the debounced
/// push loop, refetch-based pulls, and per-trip realtime triggers. A plain
/// actor (not `@ModelActor`) — every actual SwiftData read/write is delegated
/// to `store`, the one dedicated `ModelActor` (see `SyncStore`'s doc
/// comment for why the two are split).
///
/// Owned once for the app's lifetime (created alongside the `ModelContainer`
/// in `TriptoApp` and handed down via the environment) — there is no
/// teardown path except sign-out (`wipeForSignOut`), which clears local
/// state without deallocating the engine itself.
actor SyncEngine {
    let store: SyncStore
    let status: SyncStatus

    /// DEBUG-only: `-simulateOffline` (M1 brief) pins `isOffline` and pauses
    /// both push and pull regardless of what `NWPathMonitor` reports — the
    /// simulator's network otherwise just follows the host machine's, so
    /// there's no other way to drive the offline UI in-simulator.
    private let forcedOffline: Bool

    private let pathMonitor = NWPathMonitor()
    private let pathMonitorQueue = DispatchQueue(label: "io.navbytes.tripto.sync.path-monitor")
    private var isPathOffline = false

    var pushDebounceTask: Task<Void, Never>?
    var homePullDebounceTask: Task<Void, Never>?
    var tripPullDebounceTasks: [UUID: Task<Void, Never>] = [:]

    var isPushing = false
    /// Set when `schedulePush()` is called *while a flush is already in
    /// flight* — `flushPush()` loops once more instead of exiting, rather
    /// than the caller cancelling `pushDebounceTask` (which, if that task
    /// is the very one currently awaiting a network response inside
    /// `flushPush()`, would abort an in-flight request; confirmed live —
    /// see `SyncEngine+Push.swift`'s doc comment on `schedulePush`).
    var pushRequestedWhileBusy = false
    var isPullingHome = false
    var pullingTrips: Set<UUID> = []

    var homeChannel: RealtimeChannelV2?
    var homeChannelTask: Task<Void, Never>?
    var tripChannels: [UUID: RealtimeChannelV2] = [:]
    /// One task per observed table on the trip's channel — plain `Task { }`
    /// literals (not a `TaskGroup`) specifically so each inherits this
    /// actor's isolation the well-documented way; see
    /// `SyncEngine+Realtime.swift`.
    var tripChannelTasks: [UUID: [Task<Void, Never>]] = [:]

    static let maxPushAttempts = 8
    static let pushDebounceMilliseconds: UInt64 = 300
    static let pullDebounceMilliseconds: UInt64 = 500

    init(modelContainer: ModelContainer, status: SyncStatus) {
        store = SyncStore(modelContainer: modelContainer)
        self.status = status
        forcedOffline = ProcessInfo.processInfo.arguments.contains("-simulateOffline")

        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            Task { await self.pathStatusChanged(isSatisfied: path.status == .satisfied) }
        }
        pathMonitor.start(queue: pathMonitorQueue)
    }

    /// True when either the real network is down or `-simulateOffline`
    /// forced it — every network-touching entry point gates on this.
    var isEffectivelyOffline: Bool { forcedOffline || isPathOffline }

    // MARK: - Lifecycle

    /// Called once at launch (after a session exists). Publishes the
    /// initial offline/pending state, does a first pull, and opens the
    /// home realtime channel.
    func start() async {
        await publishOffline()
        await refreshStatusCounts()
        guard !isEffectivelyOffline else { return }
        await pullHome()
        await startHomeRealtime()
        schedulePush()
    }

    /// Scene-phase `.active` trigger (SYNC_DESIGN.md push-loop triggers).
    func appDidBecomeActive() async {
        guard !isEffectivelyOffline else { return }
        schedulePush()
        scheduleHomePull()
    }

    private func pathStatusChanged(isSatisfied: Bool) async {
        let wasOffline = isEffectivelyOffline
        isPathOffline = !isSatisfied
        await publishOffline()
        if wasOffline && !isEffectivelyOffline {
            schedulePush()
            scheduleHomePull()
        }
    }

    private func publishOffline() async {
        await status.setOffline(isEffectivelyOffline)
    }

    func refreshStatusCounts() async {
        let count = (try? await store.pendingCount()) ?? 0
        let rowIds = (try? await store.allPendingRowIds()) ?? []
        await status.setPending(count: count, rowIds: rowIds)
    }

    // MARK: - Enqueue (SYNC_DESIGN.md "Local store" coalescing rules)

    /// Records/coalesces a pending upsert and kicks the debounced push loop.
    /// Callers pass the row's own DTO — this is the "SwiftData write →
    /// SyncEngine.enqueue" half of the mutation flow; the SwiftData write
    /// itself already happened on the main context before this is called.
    func enqueueUpsert(table: SyncTable, rowId: UUID, tripId: UUID?, payload: some Encodable) async {
        do {
            let data = try JSONCoding.encoder.encode(payload)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            try await store.enqueueUpsert(table: table, rowId: rowId, tripId: tripId, payloadJSON: json)
            await refreshStatusCounts()
            schedulePush()
        } catch {
            logDebug("enqueueUpsert(\(table.rawValue)) failed: \(error)")
        }
    }

    func enqueueDelete(table: SyncTable, rowId: UUID, tripId: UUID?) async {
        do {
            try await store.enqueueDelete(table: table, rowId: rowId, tripId: tripId)
            await refreshStatusCounts()
            schedulePush()
        } catch {
            logDebug("enqueueDelete(\(table.rawValue)) failed: \(error)")
        }
    }

    /// `item_assignees`-only entry point (see `ItemAssignee`'s doc comment):
    /// `rowId` (`ItemAssignee.compositeId`) is purely a local dedup key, so
    /// unlike the generic `enqueueDelete` above, the real `itemId`/
    /// `profileId` pair has to travel with the op or the push path has
    /// nothing to build `.eq("item_id", ...).eq("profile_id", ...)` from —
    /// see `SyncEngine+Push.pushDelete`'s `.itemAssignees` branch, the other
    /// half of this.
    func enqueueDeleteItemAssignee(itemId: UUID, profileId: UUID, tripId: UUID?) async {
        let rowId = ItemAssignee.compositeId(itemId: itemId, profileId: profileId)
        do {
            let payload = ItemAssigneeDTO(itemId: itemId, profileId: profileId)
            let data = try JSONCoding.encoder.encode(payload)
            let json = String(data: data, encoding: .utf8) ?? "{}"
            try await store.enqueueDelete(table: .itemAssignees, rowId: rowId, tripId: tripId, payloadJSON: json)
            await refreshStatusCounts()
            schedulePush()
        } catch {
            logDebug("enqueueDeleteItemAssignee failed: \(error)")
        }
    }

    // MARK: - DEBUG reset

    /// "Reset local cache (re-pull)" — wipes every mirrored row and the
    /// outbox, then pulls fresh, proving the server round-trip.
    func resetLocalStore() async {
        try? await store.wipeAll()
        await refreshStatusCounts()
        guard !isEffectivelyOffline else { return }
        await pullHome()
    }

    /// Sign-out: wipe local state but do not re-pull (there's no session to
    /// pull with, and a stray pull mid-sign-out could race a subsequent
    /// sign-in). `AuthManager.signOut()` calls this.
    func wipeForSignOut() async {
        await stopAllRealtime()
        try? await store.wipeAll()
        await refreshStatusCounts()
    }
}

func logDebug(_ message: @autoclosure () -> String) {
    #if DEBUG
    print("[SyncEngine] \(message())")
    #endif
}
