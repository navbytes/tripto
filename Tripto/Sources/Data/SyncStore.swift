import Foundation
import SwiftData

/// The one dedicated `ModelActor` that ever writes to the mirrored store —
/// SYNC_DESIGN.md: "All SwiftData writes on a dedicated ModelActor/context —
/// never the main context from the actor." `SyncEngine` (a plain actor that
/// also owns networking, debounce timers, and realtime channels) holds one
/// of these and routes every outbox/pull-apply write through it; it never
/// touches `@Environment(\.modelContext)` (the main context) itself.
///
/// The *initial* optimistic write for a user-initiated create/edit/delete
/// still happens on the main context, directly in the view (SYNC_DESIGN.md
/// "SwiftData write → SyncEngine.enqueue → UI reflects instantly") — that's
/// what makes it instant. This actor only ever sees that row again once a
/// pull re-applies it, or to record the outbox op describing it.
///
/// Kept deliberately minimal (no stored properties beyond what `@ModelActor`
/// synthesizes) so the macro's generated `init(modelContainer:)` is the only
/// initializer — see `SyncEngine` for where the "extra" sync state
/// (NWPathMonitor, debounce tasks, realtime channels, `SyncStatus`) lives
/// instead.
@ModelActor
actor SyncStore {}

// MARK: - Outbox

/// A `Sendable` snapshot of an `OutboxOp` row — `@Model` instances are
/// reference types tied to their originating `ModelContext` and must never
/// cross an actor boundary, so `SyncStore` hands these out instead.
struct OutboxOpSnapshot: Sendable, Equatable {
    var id: UUID
    var table: SyncTable
    var op: OutboxOpKind
    var rowId: UUID
    var tripId: UUID?
    var payloadJSON: String
    var attempts: Int
    /// See `OutboxOp.seq`'s doc comment — exposed so a test (or, if it ever
    /// proves useful, the push loop) can assert FIFO order was actually
    /// derived from `seq`, not incidentally from fetch order.
    var seq: Int
}

extension SyncStore {
    /// Coalescing rule: one pending upsert per `rowId`; a newer local edit
    /// replaces the previous op's payload rather than queuing a second one.
    func enqueueUpsert(table: SyncTable, rowId: UUID, tripId: UUID?, payloadJSON: String) throws {
        let seq = try nextSeq()
        if let existing = try fetchOp(rowId: rowId) {
            existing.tableRaw = table.rawValue
            existing.op = .upsert
            existing.tripId = tripId
            existing.payloadJSON = payloadJSON
            existing.createdAt = .now
            existing.seq = seq
            // A fresh edit deserves a fresh retry budget rather than
            // inheriting a near-exhausted one from an unrelated earlier op.
            existing.attempts = 0
            existing.lastError = nil
        } else {
            modelContext.insert(
                OutboxOp(
                    tableRaw: table.rawValue,
                    opRaw: OutboxOpKind.upsert.rawValue,
                    rowId: rowId,
                    tripId: tripId,
                    payloadJSON: payloadJSON,
                    seq: seq
                )
            )
        }
        try modelContext.save()
    }

    /// Coalescing rule: a delete supersedes any pending upsert for the row.
    ///
    /// `payloadJSON` defaults to empty — every table but `item_assignees`
    /// deletes by a single `id` (`SyncEngine+Push.pushDelete`'s default
    /// path), so there's nothing to stash. `item_assignees` has no such
    /// column (composite PK `item_id`+`profile_id`); its dedicated
    /// `SyncEngine.enqueueDeleteItemAssignee` passes both columns through
    /// here so the push path can build the right `.eq(...).eq(...)` filter —
    /// see `ItemAssignee`'s doc comment.
    func enqueueDelete(table: SyncTable, rowId: UUID, tripId: UUID?, payloadJSON: String = "") throws {
        let seq = try nextSeq()
        if let existing = try fetchOp(rowId: rowId) {
            existing.tableRaw = table.rawValue
            existing.op = .delete
            existing.tripId = tripId
            existing.payloadJSON = payloadJSON
            existing.createdAt = .now
            existing.seq = seq
            existing.attempts = 0
            existing.lastError = nil
        } else {
            modelContext.insert(
                OutboxOp(
                    tableRaw: table.rawValue,
                    opRaw: OutboxOpKind.delete.rawValue,
                    rowId: rowId,
                    tripId: tripId,
                    payloadJSON: payloadJSON,
                    seq: seq
                )
            )
        }
        try modelContext.save()
    }

    /// Next monotonic `seq` value, derived from the current on-disk max
    /// rather than an in-process counter — an actor-local counter would
    /// reset to 0 on relaunch and could collide with ops still queued from a
    /// previous run; re-deriving from disk survives that.
    private func nextSeq() throws -> Int {
        var descriptor = FetchDescriptor<OutboxOp>(sortBy: [SortDescriptor(\.seq, order: .reverse)])
        descriptor.fetchLimit = 1
        return ((try modelContext.fetch(descriptor).first?.seq) ?? -1) + 1
    }

    /// FIFO-by-`seq` snapshot of every queued op, oldest first (push sends
    /// ops in this order).
    ///
    /// F2 (reviewer, MED): `createdAt` is a secondary key, not the primary
    /// one — every `OutboxOp` row written before the `seq` column existed
    /// lightweight-migrated to `seq == 0` (`OutboxOp.seq`'s own doc
    /// comment), so sorting by `seq` alone leaves any such rows' relative
    /// order undefined against each other. `createdAt` breaks that tie the
    /// same way FIFO order worked before `seq` existed; it never overrides
    /// a real (non-tied) `seq` ordering, since every fresh enqueue/coalesce
    /// assigns a `seq` strictly greater than every prior one.
    func pendingOps() throws -> [OutboxOpSnapshot] {
        let descriptor = FetchDescriptor<OutboxOp>(
            sortBy: [SortDescriptor(\.seq, order: .forward), SortDescriptor(\.createdAt, order: .forward)]
        )
        return try modelContext.fetch(descriptor).compactMap { op in
            guard let table = op.table else { return nil }
            return OutboxOpSnapshot(
                id: op.id,
                table: table,
                op: op.op,
                rowId: op.rowId,
                tripId: op.tripId,
                payloadJSON: op.payloadJSON,
                attempts: op.attempts,
                seq: op.seq
            )
        }
    }

    func pendingCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<OutboxOp>())
    }

    /// Every row id with a queued op, regardless of table — pull-apply uses
    /// this to protect rows with unpushed local edits (Principle 2: "a pull
    /// never clobbers rows with pending local ops").
    func allPendingRowIds() throws -> Set<UUID> {
        Set(try modelContext.fetch(FetchDescriptor<OutboxOp>()).map(\.rowId))
    }

    /// Success — the op is done, remove it.
    func markPushed(opId: UUID) throws {
        guard let op = try fetchOp(id: opId) else { return }
        modelContext.delete(op)
        try modelContext.save()
    }

    /// Transient failure (network blip, 5xx): keep the op, bump attempts so
    /// the engine's backoff can widen next time.
    func markTransientFailure(opId: UUID, error: String) throws {
        guard let op = try fetchOp(id: opId) else { return }
        op.attempts += 1
        op.lastError = error
        try modelContext.save()
    }

    /// Permanent failure (RLS denial, check violation, or retry budget
    /// exhausted): drop the op so it never retries forever, and leave a
    /// trace (with whether it's worth offering "Try again" on) for the UI
    /// to surface non-destructively — see `SyncIssueBanner`/`SyncIssuesSheet`.
    func markPermanentFailure(opId: UUID, rowId: UUID, table: SyncTable, message: String, retriable: Bool) throws {
        if let op = try fetchOp(id: opId) {
            modelContext.delete(op)
        }
        modelContext.insert(SyncIssue(rowId: rowId, tableRaw: table.rawValue, message: message, retriable: retriable))
        try modelContext.save()
    }

    private func fetchOp(id: UUID) throws -> OutboxOp? {
        var descriptor = FetchDescriptor<OutboxOp>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchOp(rowId: UUID) throws -> OutboxOp? {
        var descriptor = FetchDescriptor<OutboxOp>(predicate: #Predicate { $0.rowId == rowId })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

// MARK: - Sync issues (FIX #1: surfacing a permanently-failed write)

extension SyncStore {
    /// Every outstanding `SyncIssue`, newest first — `SyncEngine.refreshStatusCounts()`
    /// republishes this onto `SyncStatus.syncIssues` after every mutation/flush/
    /// failure, same as `pendingCount`/`allPendingRowIds` above.
    func allIssues() throws -> [SyncIssueSnapshot] {
        let descriptor = FetchDescriptor<SyncIssue>(sortBy: [SortDescriptor(\.at, order: .reverse)])
        return try modelContext.fetch(descriptor).map { issue in
            SyncIssueSnapshot(
                id: issue.id, rowId: issue.rowId, tableRaw: issue.tableRaw,
                message: issue.message, at: issue.at, retriable: issue.retriable
            )
        }
    }

    /// "Dismiss" on a single issue — the doomed local edit itself is left
    /// alone here (it reverts to server truth on the next pull once nothing
    /// protects it; see `SyncEngine.dismissIssue`'s doc comment), this just
    /// clears the notice.
    func dismissIssue(id: UUID) throws {
        if let issue = try fetchIssue(id: id) {
            modelContext.delete(issue)
            try modelContext.save()
        }
    }

    /// "Dismiss all" in `SyncIssuesSheet`.
    func dismissAllIssues() throws {
        try modelContext.delete(model: SyncIssue.self)
        try modelContext.save()
    }

    /// Rebuilds and (re-)queues an upsert straight from the row's current
    /// local state — the "Try again" action on a retriable sync issue
    /// (`SyncEngine.retryIssue`). Reuses `enqueueUpsert`'s own coalescing
    /// path above rather than inserting an `OutboxOp` directly, so a retry
    /// behaves exactly like any other edit to that row.
    ///
    /// Only the four plain-`id`-keyed, DTO-backed tables are retriable this
    /// way; `.itemAssignees` has no single `id` to look a row up by
    /// (composite key — see `ItemAssignee`'s doc comment), and any row
    /// that's since vanished locally (its trip was deleted, or it was
    /// edited away in the meantime by a pull) has nothing left to re-send.
    /// Both cases return `false` — the caller (`SyncEngine.retryIssue`)
    /// still dismisses the issue either way, it just doesn't get a retry.
    @discardableResult
    func reenqueueUpsertFromLocalRow(rowId: UUID, table: SyncTable) throws -> Bool {
        switch table {
        case .itineraryItems:
            guard let model = try fetchOne(ItineraryItem.self, predicate: #Predicate { $0.id == rowId }) else { return false }
            try enqueueDTOUpsert(model.toDTO(), table: table, rowId: rowId, tripId: model.tripId)
        case .packingItems:
            guard let model = try fetchOne(PackingItem.self, predicate: #Predicate { $0.id == rowId }) else { return false }
            try enqueueDTOUpsert(model.toDTO(), table: table, rowId: rowId, tripId: model.tripId)
        case .trips:
            guard let model = try fetchOne(Trip.self, predicate: #Predicate { $0.id == rowId }) else { return false }
            try enqueueDTOUpsert(model.toDTO(), table: table, rowId: rowId, tripId: model.id)
        case .tripProfiles:
            guard let model = try fetchOne(TripProfile.self, predicate: #Predicate { $0.id == rowId }) else { return false }
            try enqueueDTOUpsert(model.toDTO(), table: table, rowId: rowId, tripId: model.tripId)
        case .profiles, .tripMembers, .shareLinks, .invites, .itemAssignees:
            return false
        }
        return true
    }

    /// Shared JSON-encode step for `reenqueueUpsertFromLocalRow`'s four
    /// branches above — the same `JSONCoding.encoder` a live
    /// `SyncEngine.enqueueUpsert` call already uses for this payload shape.
    private func enqueueDTOUpsert(_ dto: some Encodable, table: SyncTable, rowId: UUID, tripId: UUID?) throws {
        let data = try JSONCoding.encoder.encode(dto)
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try enqueueUpsert(table: table, rowId: rowId, tripId: tripId, payloadJSON: json)
    }

    /// One-off fetch-by-id helper for `reenqueueUpsertFromLocalRow`'s four
    /// branches — a thin wrapper, not a generalized replacement for this
    /// file's usual concrete-per-table shape (`#Predicate` needs a concrete
    /// model type at each call site anyway, so each branch still builds its
    /// own `$0.id == rowId` predicate; this just avoids repeating the
    /// descriptor/fetchLimit boilerplate four times).
    private func fetchOne<T: PersistentModel>(_ type: T.Type, predicate: Predicate<T>) throws -> T? {
        var descriptor = FetchDescriptor<T>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }

    private func fetchIssue(id: UUID) throws -> SyncIssue? {
        var descriptor = FetchDescriptor<SyncIssue>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try modelContext.fetch(descriptor).first
    }
}

// MARK: - DEBUG reset

extension SyncStore {
    /// Wipes every mirrored row plus the outbox and sync-issue log — the
    /// DEBUG "Reset local cache (re-pull)" menu action. Callers re-pull
    /// immediately afterward; this only clears local state.
    func wipeAll() throws {
        try modelContext.delete(model: Profile.self)
        try modelContext.delete(model: Trip.self)
        try modelContext.delete(model: TripMember.self)
        try modelContext.delete(model: TripProfile.self)
        try modelContext.delete(model: ItineraryItem.self)
        try modelContext.delete(model: PackingItem.self)
        try modelContext.delete(model: ItemAssignee.self)
        try modelContext.delete(model: TripShareLink.self)
        try modelContext.delete(model: Invite.self)
        try modelContext.delete(model: OutboxOp.self)
        try modelContext.delete(model: SyncIssue.self)
        try modelContext.save()
    }
}
