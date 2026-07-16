import Foundation
import SwiftData

/// A single queued write, waiting to be pushed to PostgREST (SYNC_DESIGN.md
/// "Local store" / "Engine"). Not a mirrored server table — this is sync
/// bookkeeping that lives only on-device.
///
/// Coalescing rules (enforced by `SyncEngine.enqueueUpsert`/`enqueueDelete`,
/// not by anything on this type itself):
/// - One pending upsert per `rowId` — a newer local edit replaces the
///   previous op's `payloadJSON` in place rather than queuing a second op.
/// - A delete supersedes any pending upsert for that row (the row is going
///   away; the stale upsert would just race it pointlessly).
@Model
final class OutboxOp {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    /// Monotonic FIFO order key, assigned by `SyncStore` from the current
    /// on-disk max on every enqueue/coalesce. `createdAt` alone ties when two
    /// ops are enqueued back to back with no I/O between them (`Date`'s
    /// resolution isn't the issue; two calls can just land in the same
    /// instant) — `pendingOps()` sorts by this instead. Defaulted so
    /// existing on-disk rows lightweight-migrate cleanly; every real
    /// enqueue/coalesce path assigns a fresh value.
    var seq: Int = 0
    var tableRaw: String
    var opRaw: String
    var rowId: UUID
    var tripId: UUID?
    /// Full row snapshot for an upsert, JSON-encoded via `JSONCoding`. Empty
    /// for a delete op (nothing to send but the id).
    var payloadJSON: String
    var attempts: Int
    var lastError: String?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        tableRaw: String,
        opRaw: String,
        rowId: UUID,
        tripId: UUID?,
        payloadJSON: String,
        attempts: Int = 0,
        lastError: String? = nil,
        seq: Int = 0
    ) {
        self.id = id
        self.createdAt = createdAt
        self.tableRaw = tableRaw
        self.opRaw = opRaw
        self.rowId = rowId
        self.tripId = tripId
        self.payloadJSON = payloadJSON
        self.attempts = attempts
        self.lastError = lastError
        self.seq = seq
    }

    var table: SyncTable? { SyncTable(rawValue: tableRaw) }
    var op: OutboxOpKind {
        get { OutboxOpKind(rawValue: opRaw) ?? .upsert }
        set { opRaw = newValue.rawValue }
    }
}
