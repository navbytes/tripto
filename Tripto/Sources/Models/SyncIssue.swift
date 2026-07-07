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

    init(
        id: UUID = UUID(),
        rowId: UUID,
        tableRaw: String,
        message: String,
        at: Date = .now
    ) {
        self.id = id
        self.rowId = rowId
        self.tableRaw = tableRaw
        self.message = message
        self.at = at
    }

    var table: SyncTable? { SyncTable(rawValue: tableRaw) }
}
