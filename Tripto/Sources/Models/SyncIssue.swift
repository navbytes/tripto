import Foundation
import SwiftData

/// A record of an outbox op the engine gave up on — either the server
/// rejected it outright (RLS denial / check violation) or it exhausted its
/// retry budget (SYNC_DESIGN.md "Engine" push loop). Surfaced as a
/// non-blocking toast/attribution in the UI; never retried automatically
/// once recorded here (the row stays whatever the last successful pull
/// says it is).
@Model
final class SyncIssue {
    @Attribute(.unique) var id: UUID
    var rowId: UUID
    var tableRaw: String
    var message: String
    var at: Date
    /// Whether retrying the *same* write could plausibly succeed —
    /// `SyncEngine+Push.PushOutcome.permanent(retriable:)`'s "rejected
    /// (RLS/constraint, never)" vs "exhausted budget (maybe, later)" split.
    /// Defaulted (both here and on the initializer) so adding this property
    /// is a purely additive, migration-safe change to this LOCAL-only cache
    /// model — no existing row becomes invalid, it just reads as "not
    /// retriable" until the next failure re-records it.
    var retriable: Bool = false

    init(
        id: UUID = UUID(),
        rowId: UUID,
        tableRaw: String,
        message: String,
        at: Date = .now,
        retriable: Bool = false
    ) {
        self.id = id
        self.rowId = rowId
        self.tableRaw = tableRaw
        self.message = message
        self.at = at
        self.retriable = retriable
    }

    var table: SyncTable? { SyncTable(rawValue: tableRaw) }
}

/// A `Sendable` snapshot of a `SyncIssue` row — same reasoning as
/// `OutboxOpSnapshot` (`SyncStore.swift`'s doc comment): `@Model` instances
/// are reference types tied to their originating `ModelContext` and must
/// never cross an actor boundary, so `SyncStore.allIssues()` hands these out
/// instead, and `SyncStatus.syncIssues` is published in this shape.
struct SyncIssueSnapshot: Sendable, Equatable, Identifiable {
    let id: UUID
    let rowId: UUID
    let tableRaw: String
    let message: String
    let at: Date
    let retriable: Bool
}
