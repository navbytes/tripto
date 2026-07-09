import Foundation

/// Pure progress/grouping logic behind the Packing screen (this milestone's
/// brief §4: "progress header ('{done} of {total} packed', %, gradient
/// bar)", "grouped by group_key (only non-empty groups)") — kept
/// SwiftData/view-free so `PackingListView` stays a thin renderer, same
/// split as `PersonFilter`/`TimelineBuilder`.
enum PackingProgress {
    struct Summary: Equatable {
        let done: Int
        let total: Int

        /// Rounded to the nearest whole percent; 0 for an empty list rather
        /// than a division-by-zero NaN.
        var percent: Int {
            guard total > 0 else { return 0 }
            return Int((Double(done) / Double(total) * 100).rounded())
        }
    }

    static func summary(for items: [PackingItem]) -> Summary {
        Summary(done: items.filter(\.isDone).count, total: items.count)
    }
}

enum PackingGrouping {
    /// Fixed display order (documents/kids/shared first, matching
    /// docs/TripAppFamily.jsx's `Packing` mockup; clothing/custom after).
    static let order: [PackingGroupKey] = [.documents, .kids, .shared, .clothing, .custom]

    /// Groups `items` by `group_key` in `order`, omitting any group with no
    /// items at all (this milestone's brief: "only non-empty groups" — the
    /// mockup's 3-group example never shows an empty section, so this is
    /// the rule that generalizes it to all 5 `PackingGroupKey` cases).
    ///
    /// UX audit finding 2: within each group, unpacked items sort before
    /// packed ones (stable by `createdAt` within each half) so "what's left
    /// to pack" always scans from the top of the group instead of being
    /// interleaved with items already done. This also gives `@Query`'s
    /// previously insertion-order results a deterministic order — see the
    /// `applyUITestAutopilotIfNeeded` doc comment in `PackingListView` that
    /// already flagged that as unpredictable.
    static func groups(for items: [PackingItem]) -> [(key: PackingGroupKey, items: [PackingItem])] {
        let grouped = Dictionary(grouping: items, by: \.groupKey)
        return order.compactMap { key in
            guard let groupItems = grouped[key], !groupItems.isEmpty else { return nil }
            let sorted = groupItems.sorted { a, b in
                a.isDone == b.isDone ? a.createdAt < b.createdAt : (!a.isDone && b.isDone)
            }
            return (key, sorted)
        }
    }
}

/// Client-side convenience mirror of the live `packing_items` RLS policies
/// (confirmed via `list_tables`/`pg_policies`, not just ACCEPTANCE.md's
/// prose) — never the real security boundary (CLAUDE.md).
enum PackingPermissions {
    /// Add / toggle `is_done` / reassign / edit label & group
    /// (`packing_items_insert`/`_update`): organizer or companion,
    /// unrestricted to the row's own creator — unlike itinerary items, any
    /// companion may update *any* packing item, not just one they added.
    static func canManage(role: TripRole?) -> Bool {
        role == .organizer || role == .companion
    }

    /// Delete (`packing_items_delete`, confirmed live): organizer role, OR
    /// the row's own creator — literally `created_by = auth.uid()` with no
    /// role check of its own, so a companion who added an item and was
    /// later demoted to viewer could still delete that one item. Matches
    /// the policy exactly rather than reusing `ItemPermissions.canEdit`'s
    /// stricter "must currently hold companion" shape.
    static func canDelete(item: PackingItem, role: TripRole?, userId: UUID?) -> Bool {
        role == .organizer || (userId != nil && item.createdBy == userId)
    }
}
