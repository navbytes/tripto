import Foundation

/// The one rule pull-apply follows everywhere (SYNC_DESIGN.md "Apply =
/// upsert by id; then delete local rows absent from the server response
/// unless they have a pending outbox op"), factored out as plain `Set`
/// arithmetic so it's unit testable with no SwiftData/network involved.
///
/// Pending rows are excluded up front here, but note `SyncStore`'s
/// `applyX` methods also skip *upserting* a pending row's fields, not just
/// deleting it — Principle 2 ("a pull never clobbers rows with pending
/// local ops") applies to both halves of "apply", not only deletion.
enum SyncReconcile {
    /// Local ids that no longer appear in the latest pull and have no
    /// unpushed local edit protecting them — safe to delete.
    ///
    /// `skippedCount` is the matching `LossyCodableList.skippedCount` for
    /// this table's pull: how many rows failed tolerant decode and were
    /// dropped before `pulledIds` was ever built. When it's nonzero,
    /// "absent from `pulledIds`" no longer reliably means "the server
    /// deleted it" — it may just mean this pull's decode of that row
    /// failed — so the whole delete phase is skipped for the table this
    /// pull (upserts of the rows that DID decode are unaffected). D1: a
    /// malformed-but-still-present server row must never be silently
    /// deleted locally.
    static func idsToDelete(
        existingIds: Set<UUID>,
        pulledIds: Set<UUID>,
        pendingIds: Set<UUID>,
        skippedCount: Int = 0
    ) -> Set<UUID> {
        guard skippedCount == 0 else { return [] }
        return existingIds.subtracting(pulledIds).subtracting(pendingIds)
    }
}
