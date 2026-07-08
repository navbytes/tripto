import Foundation
import SwiftData

/// Pull-apply for each mirrored table. Every method follows the same shape
/// (SYNC_DESIGN.md): upsert-by-id, skipping rows with a pending outbox op
/// entirely (neither their fields nor their existence are touched — see
/// `SyncReconcile`'s doc comment), then delete local rows absent from the
/// pull that aren't protected by a pending op.
///
/// Deliberately concrete per table rather than generic: SwiftData's
/// `#Predicate` macro needs a concrete model type at each call site, and at
/// this scale (a family's trips, not a fleet's) eight plain methods are
/// easier to read and debug than one clever generic one — SYNC_DESIGN.md's
/// own instruction is to "keep it boring."
extension SyncStore {
    // MARK: Home scope (pullHome — unfiltered; RLS already scopes these to
    // "my trips" server-side, so there's no client-side trip_id filter to
    // apply on top of it).

    func applyProfiles(_ dtos: [ProfileDTO]) throws {
        let pending = try allPendingRowIds()
        let existing = try modelContext.fetch(FetchDescriptor<Profile>())
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let pulledIds = Set(dtos.map(\.id))

        for dto in dtos where !pending.contains(dto.id) {
            if let model = existingById[dto.id] {
                model.apply(dto)
            } else {
                modelContext.insert(Profile(dto: dto))
            }
        }

        let toDelete = SyncReconcile.idsToDelete(
            existingIds: Set(existingById.keys), pulledIds: pulledIds, pendingIds: pending
        )
        for id in toDelete {
            if let model = existingById[id] { modelContext.delete(model) }
        }
        try modelContext.save()
    }

    func applyTrips(_ dtos: [TripDTO]) throws {
        let pending = try allPendingRowIds()
        let existing = try modelContext.fetch(FetchDescriptor<Trip>())
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let pulledIds = Set(dtos.map(\.id))

        for dto in dtos where !pending.contains(dto.id) {
            if let model = existingById[dto.id] {
                model.apply(dto)
            } else {
                modelContext.insert(Trip(dto: dto))
            }
        }

        let toDelete = SyncReconcile.idsToDelete(
            existingIds: Set(existingById.keys), pulledIds: pulledIds, pendingIds: pending
        )
        for id in toDelete {
            if let model = existingById[id] { modelContext.delete(model) }
        }
        try modelContext.save()
    }

    func applyTripMembers(_ dtos: [TripMemberDTO]) throws {
        let pending = try allPendingRowIds()
        let existing = try modelContext.fetch(FetchDescriptor<TripMember>())
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let pulledIds = Set(dtos.map(\.id))

        for dto in dtos where !pending.contains(dto.id) {
            if let model = existingById[dto.id] {
                model.apply(dto)
            } else {
                modelContext.insert(TripMember(dto: dto))
            }
        }

        let toDelete = SyncReconcile.idsToDelete(
            existingIds: Set(existingById.keys), pulledIds: pulledIds, pendingIds: pending
        )
        for id in toDelete {
            if let model = existingById[id] { modelContext.delete(model) }
        }
        try modelContext.save()
    }

    func applyTripProfiles(_ dtos: [TripProfileDTO]) throws {
        let pending = try allPendingRowIds()
        let existing = try modelContext.fetch(FetchDescriptor<TripProfile>())
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let pulledIds = Set(dtos.map(\.id))

        for dto in dtos where !pending.contains(dto.id) {
            if let model = existingById[dto.id] {
                model.apply(dto)
            } else {
                modelContext.insert(TripProfile(dto: dto))
            }
        }

        let toDelete = SyncReconcile.idsToDelete(
            existingIds: Set(existingById.keys), pulledIds: pulledIds, pendingIds: pending
        )
        for id in toDelete {
            if let model = existingById[id] { modelContext.delete(model) }
        }
        try modelContext.save()
    }

    /// Deletes local rows in the home-scope tables (plus every trip-scope
    /// table) whose `tripId` no longer matches any locally-known trip — the
    /// cascade that `pullHome`'s "delete absent trips" step doesn't reach on
    /// its own, since `trip_members`/`itinerary_items`/etc. aren't refetched
    /// by `pullHome`. A row with a pending outbox op is still protected.
    func pruneOrphans() throws {
        let validTripIds = Set(try modelContext.fetch(FetchDescriptor<Trip>()).map(\.id))
        let pending = try allPendingRowIds()

        for row in try modelContext.fetch(FetchDescriptor<TripMember>())
        where !validTripIds.contains(row.tripId) && !pending.contains(row.id) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<TripProfile>())
        where !validTripIds.contains(row.tripId) && !pending.contains(row.id) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<ItineraryItem>())
        where !validTripIds.contains(row.tripId) && !pending.contains(row.id) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<PackingItem>())
        where !validTripIds.contains(row.tripId) && !pending.contains(row.id) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<TripShareLink>())
        where !validTripIds.contains(row.tripId) && !pending.contains(row.id) {
            modelContext.delete(row)
        }
        for row in try modelContext.fetch(FetchDescriptor<Invite>())
        where !validTripIds.contains(row.tripId) && !pending.contains(row.id) {
            modelContext.delete(row)
        }
        // `ItemAssignee` has no `tripId` of its own (composite PK item_id+
        // profile_id) — computed independently of the loop above, rather
        // than re-fetching `ItineraryItem` after it stages deletes, so this
        // doesn't depend on whether SwiftData's in-context fetch reflects
        // not-yet-saved deletes.
        let validItemIds = Set(
            try modelContext.fetch(
                FetchDescriptor<ItineraryItem>(predicate: #Predicate { validTripIds.contains($0.tripId) })
            ).map(\.id)
        )
        for row in try modelContext.fetch(FetchDescriptor<ItemAssignee>())
        where !validItemIds.contains(row.itemId) && !pending.contains(row.id) {
            modelContext.delete(row)
        }
        try modelContext.save()
    }

    // MARK: Trip scope (pullTrip(_:) — explicitly filtered to one trip;
    // unlike the home tables, an unfiltered select here would return every
    // trip's rows the caller can see, not just the one being pulled).

    func applyItineraryItems(_ dtos: [ItineraryItemDTO], tripId: UUID) throws {
        let pending = try allPendingRowIds()
        let existing = try modelContext.fetch(
            FetchDescriptor<ItineraryItem>(predicate: #Predicate { $0.tripId == tripId })
        )
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let pulledIds = Set(dtos.map(\.id))

        for dto in dtos where !pending.contains(dto.id) {
            if let model = existingById[dto.id] {
                model.apply(dto)
            } else {
                modelContext.insert(ItineraryItem(dto: dto))
            }
        }

        let toDelete = SyncReconcile.idsToDelete(
            existingIds: Set(existingById.keys), pulledIds: pulledIds, pendingIds: pending
        )
        for id in toDelete {
            if let model = existingById[id] { modelContext.delete(model) }
        }
        try modelContext.save()
    }

    func applyPackingItems(_ dtos: [PackingItemDTO], tripId: UUID) throws {
        let pending = try allPendingRowIds()
        let existing = try modelContext.fetch(
            FetchDescriptor<PackingItem>(predicate: #Predicate { $0.tripId == tripId })
        )
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let pulledIds = Set(dtos.map(\.id))

        for dto in dtos where !pending.contains(dto.id) {
            if let model = existingById[dto.id] {
                model.apply(dto)
            } else {
                modelContext.insert(PackingItem(dto: dto))
            }
        }

        let toDelete = SyncReconcile.idsToDelete(
            existingIds: Set(existingById.keys), pulledIds: pulledIds, pendingIds: pending
        )
        for id in toDelete {
            if let model = existingById[id] { modelContext.delete(model) }
        }
        try modelContext.save()
    }

    /// `item_assignees` has no `trip_id` column of its own (composite PK
    /// item_id+profile_id — see `ItemAssignee`'s doc comment), so unlike
    /// every sibling in this section, "existing rows for this trip" is
    /// derived by first finding this trip's own local item ids, then
    /// filtering assignee rows by `itemId` membership rather than a direct
    /// `tripId` predicate. `dtos` is expected to already be scoped to this
    /// trip's items by the caller (`SyncEngine+Pull.pullTrip` queries
    /// `item_assignees` with `.in("item_id", values:)` against the same
    /// pull's own `itineraryItems` result) — this method doesn't re-filter
    /// `dtos` itself, only the *local* existing/delete-candidate set.
    func applyItemAssignees(_ dtos: [ItemAssigneeDTO], tripId: UUID) throws {
        let pending = try allPendingRowIds()
        let localItemIds = Set(
            try modelContext.fetch(FetchDescriptor<ItineraryItem>(predicate: #Predicate { $0.tripId == tripId }))
                .map(\.id)
        )
        let existing = try modelContext.fetch(
            FetchDescriptor<ItemAssignee>(predicate: #Predicate { localItemIds.contains($0.itemId) })
        )
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let pulledIds = Set(dtos.map { ItemAssignee.compositeId(itemId: $0.itemId, profileId: $0.profileId) })

        for dto in dtos {
            let id = ItemAssignee.compositeId(itemId: dto.itemId, profileId: dto.profileId)
            guard !pending.contains(id) else { continue }
            if let model = existingById[id] {
                model.apply(dto)
            } else {
                modelContext.insert(ItemAssignee(dto: dto))
            }
        }

        let toDelete = SyncReconcile.idsToDelete(
            existingIds: Set(existingById.keys), pulledIds: pulledIds, pendingIds: pending
        )
        for id in toDelete {
            if let model = existingById[id] { modelContext.delete(model) }
        }
        try modelContext.save()
    }

    /// RLS returns `[]` here for non-organizers — handled the same as any
    /// other empty pull (nothing to upsert; anything local gets reconciled
    /// away below unless pending), no special-casing needed.
    func applyShareLinks(_ dtos: [ShareLinkDTO], tripId: UUID) throws {
        let pending = try allPendingRowIds()
        let existing = try modelContext.fetch(
            FetchDescriptor<TripShareLink>(predicate: #Predicate { $0.tripId == tripId })
        )
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let pulledIds = Set(dtos.map(\.id))

        for dto in dtos where !pending.contains(dto.id) {
            if let model = existingById[dto.id] {
                model.apply(dto)
            } else {
                modelContext.insert(TripShareLink(dto: dto))
            }
        }

        let toDelete = SyncReconcile.idsToDelete(
            existingIds: Set(existingById.keys), pulledIds: pulledIds, pendingIds: pending
        )
        for id in toDelete {
            if let model = existingById[id] { modelContext.delete(model) }
        }
        try modelContext.save()
    }

    /// Same RLS shape as `applyShareLinks` — see its doc comment.
    func applyInvites(_ dtos: [InviteDTO], tripId: UUID) throws {
        let pending = try allPendingRowIds()
        let existing = try modelContext.fetch(
            FetchDescriptor<Invite>(predicate: #Predicate { $0.tripId == tripId })
        )
        let existingById = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        let pulledIds = Set(dtos.map(\.id))

        for dto in dtos where !pending.contains(dto.id) {
            if let model = existingById[dto.id] {
                model.apply(dto)
            } else {
                modelContext.insert(Invite(dto: dto))
            }
        }

        let toDelete = SyncReconcile.idsToDelete(
            existingIds: Set(existingById.keys), pulledIds: pulledIds, pendingIds: pending
        )
        for id in toDelete {
            if let model = existingById[id] { modelContext.delete(model) }
        }
        try modelContext.save()
    }
}
