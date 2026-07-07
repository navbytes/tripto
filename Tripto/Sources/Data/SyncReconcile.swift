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
    static func idsToDelete(
        existingIds: Set<UUID>,
        pulledIds: Set<UUID>,
        pendingIds: Set<UUID>
    ) -> Set<UUID> {
        existingIds.subtracting(pulledIds).subtracting(pendingIds)
    }
}
