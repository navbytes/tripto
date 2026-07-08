import Foundation
import SwiftData

/// Mirrors `public.item_assignees` — "who an item is for," powering the
/// "Just mine" filter (BUILD_PLAN.md §3.3, §5.4) and the assignee avatar
/// cluster on timeline cards. The server row is genuinely just two columns,
/// confirmed live against the schema (M4 brief; `list_tables`):
/// `item_id uuid, profile_id uuid, primary key (item_id, profile_id)`. No
/// `id`, no `created_at` — the pair *is* the row.
///
/// RLS (confirmed live against `item_assignees_insert`/`_delete`): organizer
/// of the item's trip, OR the companion who created that `itinerary_item` —
/// the exact same predicate `ItemPermissions.canEdit` already encodes for
/// editing the item itself (see `ItemAssigneePermissionsTests`). SELECT is
/// any trip member (via the parent item's trip).
///
/// ## The composite-key problem
/// Every other mirrored table (`SyncStore`, `OutboxOp`) is keyed by a single
/// `rowId: UUID` — one pending upsert per row, one `.eq("id", value:)` for
/// deletes. This table has no such column. Two deliberate, narrowly-scoped
/// accommodations, both documented at their call sites rather than
/// generalizing the whole outbox:
/// 1. **Local identity**: `id` here is a *synthetic*, deterministic
///    combination of `itemId`/`profileId` (see `compositeId`) — enough for
///    SwiftData's `@Attribute(.unique)`, for `OutboxOp.rowId` coalescing
///    (assign-then-unassign-then-reassign of the same pair collapses to one
///    pending op, same as every other table), and for local dictionary
///    lookups. It has no meaning server-side and is never sent over the wire.
/// 2. **Composite delete**: `SyncEngine.enqueueDeleteItemAssignee(itemId:
///    profileId:tripId:)` is a dedicated entry point (not the generic
///    `enqueueDelete`) that stashes both real columns in the outbox op's
///    payload so `SyncEngine+Push.pushDelete`'s `.itemAssignees` branch can
///    issue `.eq("item_id", ...).eq("profile_id", ...)` instead of the
///    generic `.eq("id", ...)`. See that method's doc comment.
@Model
final class ItemAssignee {
    @Attribute(.unique) var id: UUID
    var itemId: UUID
    var profileId: UUID

    init(itemId: UUID, profileId: UUID) {
        self.id = ItemAssignee.compositeId(itemId: itemId, profileId: profileId)
        self.itemId = itemId
        self.profileId = profileId
    }

    /// Deterministic (not random) so re-assigning/re-pulling the same pair
    /// always lands on the same local identity — required for both
    /// SwiftData upsert-by-id and outbox coalescing to work at all. Not a
    /// security- or collision-sensitive value (purely local bookkeeping for
    /// a few dozen rows at most), so a lightweight byte-rotation mix is
    /// enough; deliberately *not* a simple XOR (commutative — would map
    /// `(item: A, profile: B)` and a hypothetical `(item: B, profile: A)` to
    /// the same id) even though item ids and profile ids are drawn from
    /// disjoint UUID pools in practice.
    static func compositeId(itemId: UUID, profileId: UUID) -> UUID {
        let a = itemId.uuid
        let b = profileId.uuid
        let aBytes = [a.0, a.1, a.2, a.3, a.4, a.5, a.6, a.7, a.8, a.9, a.10, a.11, a.12, a.13, a.14, a.15]
        let bBytes = [b.0, b.1, b.2, b.3, b.4, b.5, b.6, b.7, b.8, b.9, b.10, b.11, b.12, b.13, b.14, b.15]
        var mixed = [UInt8](repeating: 0, count: 16)
        for i in 0..<16 {
            mixed[i] = aBytes[i] ^ bBytes[(i + 7) % 16]
        }
        let tuple = (
            mixed[0], mixed[1], mixed[2], mixed[3], mixed[4], mixed[5], mixed[6], mixed[7],
            mixed[8], mixed[9], mixed[10], mixed[11], mixed[12], mixed[13], mixed[14], mixed[15]
        )
        return UUID(uuid: tuple)
    }
}

/// Explicit, since `@Model` doesn't synthesize this (see `Trip`'s identical
/// comment) — assignee lists render in `ForEach`.
extension ItemAssignee: Identifiable {}

/// Wire shape for `item_assignees` — exactly the two real columns; `id` is
/// never encoded/decoded over the wire (see the type's doc comment).
struct ItemAssigneeDTO: Codable, Sendable, Equatable {
    var itemId: UUID
    var profileId: UUID
}

extension ItemAssignee {
    convenience init(dto: ItemAssigneeDTO) {
        self.init(itemId: dto.itemId, profileId: dto.profileId)
    }

    /// Both fields together are this row's whole identity, so "apply" never
    /// has anything to change in place — kept only for symmetry with every
    /// other mirrored model's `apply(_:)` so `SyncStore.applyItemAssignees`
    /// can follow the same upsert-by-id shape as its seven siblings.
    func apply(_ dto: ItemAssigneeDTO) {
        itemId = dto.itemId
        profileId = dto.profileId
    }

    func toDTO() -> ItemAssigneeDTO {
        ItemAssigneeDTO(itemId: itemId, profileId: profileId)
    }
}
