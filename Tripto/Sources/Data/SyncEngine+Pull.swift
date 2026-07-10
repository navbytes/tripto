import Foundation
import Supabase

/// Refetch-based pulls (SYNC_DESIGN.md: "Refetch, don't delta"). Every
/// query here relies on RLS to scope rows correctly server-side — see each
/// method's doc comment for exactly what's (and isn't) filtered client-side.
extension SyncEngine {
    /// Debounced home-pull trigger — connectivity regained, app foreground,
    /// or a realtime event on `trips`/`trip_members`/`trip_profiles`.
    func scheduleHomePull() {
        homePullDebounceTask?.cancel()
        homePullDebounceTask = Task {
            try? await Task.sleep(nanoseconds: Self.pullDebounceMilliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            await pullHome()
        }
    }

    /// "My trips" + everyone/everything Home needs to render them: members,
    /// trip_profiles (avatar stacks), and the profiles behind those members.
    /// No client-side trip_id filter on any of the four queries — RLS
    /// already scopes each to "rows I can see" (CLAUDE.md: query narrowing
    /// belongs server-side), so an unfiltered `select()` is both correct
    /// and lets all four run concurrently with no ordering dependency.
    func pullHome() async {
        guard !isPullingHome else { return }
        guard !isEffectivelyOffline else { return }
        isPullingHome = true
        defer { isPullingHome = false }

        do {
            // Decoded via `LossyCodableList` (not `[T]` directly), so one
            // malformed row on any of the four tables is skipped rather
            // than failing this entire pull — see that type's doc comment.
            async let profiles: LossyCodableList<ProfileDTO> = Supa.client.from(SyncTable.profiles.rawValue)
                .select().execute().value
            async let trips: LossyCodableList<TripDTO> = Supa.client.from(SyncTable.trips.rawValue)
                .select().execute().value
            async let members: LossyCodableList<TripMemberDTO> = Supa.client.from(SyncTable.tripMembers.rawValue)
                .select().execute().value
            async let tripProfiles: LossyCodableList<TripProfileDTO> = Supa.client.from(SyncTable.tripProfiles.rawValue)
                .select().execute().value

            let (profilesResult, tripsResult, membersResult, tripProfilesResult) =
                try await (profiles, trips, members, tripProfiles)

            try await store.applyProfiles(profilesResult.elements, skippedCount: profilesResult.skippedCount)
            try await store.applyTrips(tripsResult.elements, skippedCount: tripsResult.skippedCount)
            try await store.applyTripMembers(membersResult.elements, skippedCount: membersResult.skippedCount)
            try await store.applyTripProfiles(tripProfilesResult.elements, skippedCount: tripProfilesResult.skippedCount)
            // Cascade-clean trip-scoped tables for any trip that just
            // disappeared (deleted, or membership revoked) — see its doc
            // comment; pullHome never refetches those tables directly.
            try await store.pruneOrphans()

            await status.markSynced()
            await status.setHomePullFailed(false)
            schedulePush()
        } catch {
            logDebug("pullHome failed: \(error)")
            await status.setHomePullFailed(true)
        }
        // Deliberately on attempt-completion, not just the success path
        // above (`markSynced` only fires there) — a failed first pull
        // should degrade to the pull-failed state, not strand `HomeView`
        // on an infinite "Checking for your trips…" spinner (finding 2).
        // The early-return guards above (already pulling, offline) skip
        // this on purpose: an offline launch leaves the flag false so
        // `HomeView`'s `!isOffline` condition — not this one — governs it.
        await status.markInitialHomePullCompleted()
        await refreshStatusCounts()
    }

    /// Debounced per-trip pull trigger (realtime event on an open trip's
    /// tables, or a foreground re-pull once M2 tracks "the open trip").
    func schedulePullTrip(_ tripId: UUID) {
        tripPullDebounceTasks[tripId]?.cancel()
        tripPullDebounceTasks[tripId] = Task {
            try? await Task.sleep(nanoseconds: Self.pullDebounceMilliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            await pullTrip(tripId)
        }
    }

    /// Items/packing/share-links/invites for one trip, explicitly filtered
    /// to it — unlike `pullHome`'s tables, RLS alone would return every
    /// trip's rows here, not just the one being opened. `share_links`/
    /// `invites` legitimately come back `[]` for a non-organizer; that's a
    /// normal empty result, not an error (see `TripShareLink`'s doc comment).
    func pullTrip(_ tripId: UUID) async {
        guard !pullingTrips.contains(tripId) else { return }
        guard !isEffectivelyOffline else { return }
        pullingTrips.insert(tripId)
        defer { pullingTrips.remove(tripId) }

        do {
            // Decoded via `LossyCodableList` (not `[T]` directly), so one
            // malformed row on any of this trip's tables is skipped rather
            // than failing this entire pull — see that type's doc comment.
            async let items: LossyCodableList<ItineraryItemDTO> = Supa.client.from(SyncTable.itineraryItems.rawValue)
                .select().eq("trip_id", value: tripId).execute().value
            async let packing: LossyCodableList<PackingItemDTO> = Supa.client.from(SyncTable.packingItems.rawValue)
                .select().eq("trip_id", value: tripId).execute().value
            async let shareLinks: LossyCodableList<ShareLinkDTO> = Supa.client.from(SyncTable.shareLinks.rawValue)
                .select().eq("trip_id", value: tripId).execute().value
            async let invites: LossyCodableList<InviteDTO> = Supa.client.from(SyncTable.invites.rawValue)
                .select().eq("trip_id", value: tripId).execute().value

            let (itemsResult, packingResult, shareLinksResult, invitesResult) =
                try await (items, packing, shareLinks, invites)

            try await store.applyItineraryItems(itemsResult.elements, tripId: tripId, skippedCount: itemsResult.skippedCount)
            try await store.applyPackingItems(packingResult.elements, tripId: tripId, skippedCount: packingResult.skippedCount)
            try await store.applyShareLinks(shareLinksResult.elements, tripId: tripId, skippedCount: shareLinksResult.skippedCount)
            try await store.applyInvites(invitesResult.elements, tripId: tripId, skippedCount: invitesResult.skippedCount)

            // `item_assignees` has no `trip_id` column (composite PK
            // item_id+profile_id — `ItemAssignee`'s doc comment), so it
            // can't join the four concurrent queries above by a plain
            // `.eq("trip_id", ...)`; it depends on `itemsResult`'s ids
            // instead, so it runs after they resolve. Skipping the network
            // round trip entirely for a (rare) itemless trip, rather than
            // sending `.in("item_id", values: [])`.
            let itemIds = itemsResult.elements.map(\.id)
            let assigneesResult: LossyCodableList<ItemAssigneeDTO> = itemIds.isEmpty
                ? LossyCodableList(elements: [])
                : try await Supa.client
                    .from(SyncTable.itemAssignees.rawValue)
                    .select().in("item_id", values: itemIds).execute().value
            // The assignee query above is shaped from the DECODED item ids, so
            // whenever item rows were skipped the assignee pulled-set is also
            // incomplete — protect its delete pass with the items' skip count
            // too, or a malformed item's assignees get reconciled away as
            // "genuinely absent" (D1 residual, handoffs/D1.md).
            try await store.applyItemAssignees(
                assigneesResult.elements, tripId: tripId,
                skippedCount: assigneesResult.skippedCount + itemsResult.skippedCount)

            await status.markSynced()
            await status.setTripPullFailed(tripId, false)
        } catch {
            logDebug("pullTrip(\(tripId)) failed: \(error)")
            await status.setTripPullFailed(tripId, true)
        }
        // Attempt-completion, not just the success path above — same
        // rationale as `pullHome`'s `markInitialHomePullCompleted` call
        // (finding 2): a failed first pull should degrade to this trip's
        // normal empty states, not strand `TripView` on an infinite
        // "Checking…" placeholder. The early-return guards above
        // (already pulling this trip, offline) deliberately skip this, so
        // the offline case stays governed by `TripView`'s own
        // `!syncStatus.isOffline` check instead.
        await status.markInitialTripPullCompleted(tripId)
        await refreshStatusCounts()
    }
}
