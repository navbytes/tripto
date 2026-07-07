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
}

extension SyncStore {
    /// Coalescing rule: one pending upsert per `rowId`; a newer local edit
    /// replaces the previous op's payload rather than queuing a second one.
    func enqueueUpsert(table: SyncTable, rowId: UUID, tripId: UUID?, payloadJSON: String) throws {
        if let existing = try fetchOp(rowId: rowId) {
            existing.tableRaw = table.rawValue
            existing.op = .upsert
            existing.tripId = tripId
            existing.payloadJSON = payloadJSON
            existing.createdAt = .now
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
                    payloadJSON: payloadJSON
                )
            )
        }
        try modelContext.save()
    }

    /// Coalescing rule: a delete supersedes any pending upsert for the row.
    func enqueueDelete(table: SyncTable, rowId: UUID, tripId: UUID?) throws {
        if let existing = try fetchOp(rowId: rowId) {
            existing.tableRaw = table.rawValue
            existing.op = .delete
            existing.tripId = tripId
            existing.payloadJSON = ""
            existing.createdAt = .now
            existing.attempts = 0
            existing.lastError = nil
        } else {
            modelContext.insert(
                OutboxOp(
                    tableRaw: table.rawValue,
                    opRaw: OutboxOpKind.delete.rawValue,
                    rowId: rowId,
                    tripId: tripId,
                    payloadJSON: ""
                )
            )
        }
        try modelContext.save()
    }

    /// FIFO-by-creation snapshot of every queued op, oldest first (push
    /// sends ops in this order).
    func pendingOps() throws -> [OutboxOpSnapshot] {
        let descriptor = FetchDescriptor<OutboxOp>(sortBy: [SortDescriptor(\.createdAt, order: .forward)])
        return try modelContext.fetch(descriptor).compactMap { op in
            guard let table = op.table else { return nil }
            return OutboxOpSnapshot(
                id: op.id,
                table: table,
                op: op.op,
                rowId: op.rowId,
                tripId: op.tripId,
                payloadJSON: op.payloadJSON,
                attempts: op.attempts
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
    /// trace for the UI to surface non-destructively.
    func markPermanentFailure(opId: UUID, rowId: UUID, table: SyncTable, message: String) throws {
        if let op = try fetchOp(id: opId) {
            modelContext.delete(op)
        }
        modelContext.insert(SyncIssue(rowId: rowId, tableRaw: table.rawValue, message: message))
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
        try modelContext.delete(model: TripShareLink.self)
        try modelContext.delete(model: Invite.self)
        try modelContext.delete(model: OutboxOp.self)
        try modelContext.delete(model: SyncIssue.self)
        try modelContext.save()
    }
}
