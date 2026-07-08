import Foundation

/// Pure filtering/lookup logic behind the "Just mine" person filter
/// (BUILD_PLAN.md §5.4, this milestone's brief §3) — kept network/SwiftData-
/// free so it's unit testable the same way `SyncReconcile`/`ItemPermissions`
/// are, and so `TripView`/`ItineraryTabView` stay thin renderers over it.
enum PersonFilter {
    /// `items` scoped to `selectedProfileId` ("Everyone" is `nil` — returns
    /// `items` unfiltered).
    ///
    /// An item with **no** assignees at all is treated as "for everyone" and
    /// always stays visible, even under a specific filter — this milestone's
    /// brief for the assignee picker: "default: none = everyone." Only items
    /// that carry at least one assignee, none of whom is the selected
    /// person, are excluded. (The mockup's sample data never exercises this
    /// edge case — every item there has at least one "who" — so this is a
    /// deliberate interpretation, not copied from `TripAppFamily.jsx`.)
    static func filteredItems(
        _ items: [ItineraryItem],
        assignees: [ItemAssignee],
        selectedProfileId: UUID?
    ) -> [ItineraryItem] {
        guard let selectedProfileId else { return items }
        let assignedItemIds = Set(assignees.map(\.itemId))
        let mineItemIds = Set(assignees.filter { $0.profileId == selectedProfileId }.map(\.itemId))
        return items.filter { !assignedItemIds.contains($0.id) || mineItemIds.contains($0.id) }
    }

    /// `itemId` -> the `profileId`s assigned to it, restricted to
    /// `itemIds` — the caller's own trip's item ids. `ItemAssignee` carries
    /// no `tripId` of its own (composite PK item_id+profile_id), so scoping
    /// to "this trip" always goes through the item ids the caller already
    /// knows are theirs, never a direct predicate on the assignee rows
    /// themselves (mirrors `SyncStore.applyItemAssignees`'s same shape).
    static func assigneeProfileIds(_ assignees: [ItemAssignee], itemIds: Set<UUID>) -> [UUID: [UUID]] {
        var result: [UUID: [UUID]] = [:]
        for assignee in assignees where itemIds.contains(assignee.itemId) {
            result[assignee.itemId, default: []].append(assignee.profileId)
        }
        return result
    }
}
