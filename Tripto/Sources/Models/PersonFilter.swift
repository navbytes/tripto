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

    /// An honest breakdown for the filter banner. The old banner said "Just
    /// X's plans — 43 of 43," which reads as a lie when every item is actually
    /// *shared* (unassigned) rather than X's. This splits the visible set into
    /// "specifically assigned to X" vs "shared with everyone," plus how many are
    /// hidden because they belong only to other people.
    struct FilterSummary: Equatable {
        /// Items with at least one assignee, one of whom is the selected person.
        let assignedToPerson: Int
        /// Items with no assignees at all — shared with the whole group.
        let shared: Int
        /// Items assigned only to *other* people (excluded from the view).
        let hiddenForOthers: Int

        var total: Int { assignedToPerson + shared + hiddenForOthers }
        var visible: Int { assignedToPerson + shared }
    }

    static func summary(
        _ items: [ItineraryItem],
        assignees: [ItemAssignee],
        selectedProfileId: UUID
    ) -> FilterSummary {
        let assignedItemIds = Set(assignees.map(\.itemId))
        let mineItemIds = Set(assignees.filter { $0.profileId == selectedProfileId }.map(\.itemId))
        var assignedToPerson = 0
        var shared = 0
        var hidden = 0
        for item in items {
            if !assignedItemIds.contains(item.id) {
                shared += 1
            } else if mineItemIds.contains(item.id) {
                assignedToPerson += 1
            } else {
                hidden += 1
            }
        }
        return FilterSummary(assignedToPerson: assignedToPerson, shared: shared, hiddenForOthers: hidden)
    }

    /// UX audit finding 5: the "Just mine" selection can go stale if the
    /// filtered-to profile is deleted (locally, or pulled via realtime) —
    /// `selectedProfileFilter` would keep pointing at a `TripProfile` that
    /// no longer exists, silently hiding the rest of the trip. Returns
    /// `selection` unchanged when it's already "Everyone" (`nil`) or still
    /// present in `profileIds`; otherwise resets to `nil` so the full
    /// timeline returns and the "Everyone" chip renders selected. A silent
    /// reset is the honest minimal behavior here — the removed profile's
    /// name is already gone by the time there'd be anything to toast about.
    static func reconciledSelection(_ selection: UUID?, profileIds: Set<UUID>) -> UUID? {
        guard let selection else { return nil }
        return profileIds.contains(selection) ? selection : nil
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
