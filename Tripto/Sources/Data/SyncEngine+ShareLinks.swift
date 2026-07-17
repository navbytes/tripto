import Foundation
import Supabase

/// Wire payload for creating a new `share_links` row — only the columns the
/// client actually chooses; `token`/`created_at` are server-generated (see
/// `SyncEngine.createShareLink`'s doc comment).
private struct CreateShareLinkPayload: Encodable {
    let id: UUID
    let tripId: UUID
    let scope: String
    let revoked: Bool
}

/// Wire payload for creating a new `invites` row — same shape as
/// `CreateShareLinkPayload` above, plus the fields an invite alone carries.
private struct CreateInvitePayload: Encodable {
    let id: UUID
    let tripId: UUID
    let role: String
    let createdBy: UUID
    let revoked: Bool
}

extension SyncEngine {
    /// D-structure F1: `share_links`/`invites` are this app's one deliberate
    /// exception to SYNC_DESIGN.md's offline-first outbox path — `token` is
    /// a server-generated column default (`not null unique default
    /// encode(gen_random_bytes(16), 'hex')`) with no valid optimistic guess,
    /// so these two creates go straight to the network and read the real
    /// row back in one round trip instead of enqueueing. Returns the
    /// decoded row so the caller can build/insert its own local `@Model`
    /// (this actor never touches the main `ModelContext` — see this type's
    /// own doc comment) and present whatever UI it needs from the fields the
    /// server assigned (`token`, `createdAt`).
    func createShareLink(tripId: UUID) async throws -> ShareLinkDTO {
        let id = UUID()
        let payload = CreateShareLinkPayload(id: id, tripId: tripId, scope: ShareScope.view.rawValue, revoked: false)
        return try await withOrganizerRaceRetry {
            try await insertAndReadBack(table: .shareLinks, id: id, payload: payload, as: ShareLinkDTO.self)
        }
    }

    /// Same shape as `createShareLink` above — see that method's doc comment.
    func createInvite(role: TripRole, tripId: UUID, createdBy: UUID) async throws -> InviteDTO {
        let id = UUID()
        let payload = CreateInvitePayload(id: id, tripId: tripId, role: role.rawValue, createdBy: createdBy, revoked: false)
        return try await withOrganizerRaceRetry {
            try await insertAndReadBack(table: .invites, id: id, payload: payload, as: InviteDTO.self)
        }
    }

    /// Inserting with the representation requested back (`.select()`
    /// chained onto `.insert()`) makes PostgREST evaluate the table's SELECT
    /// policy against the RETURNING clause *as part of the same INSERT
    /// statement* — confirmed live (curl, bypassing this app entirely): the
    /// identical insert 42501s with `Prefer: return=representation` and
    /// succeeds (201) with `return=minimal`. `share_links_all`/`invites_all`
    /// are single `FOR ALL` policies whose one `trip_role(trip_id) =
    /// 'organizer'` expression backs both the INSERT's WITH CHECK and (for
    /// RETURNING) the SELECT side, and evaluating both within one statement
    /// is the trap — same class of bug `SyncEngine+Push.swift`'s
    /// `pushUpsert` doc comment documents for `trips`/`trips_select`. Fix:
    /// insert with a minimal return, then read the row back with a
    /// *separate* plain SELECT — its own request, evaluated once the INSERT
    /// (and the trigger-created membership every `share_links`/`invites`
    /// write depends on) has already committed.
    private func insertAndReadBack<Payload: Encodable, Row: Decodable>(
        table: SyncTable,
        id: UUID,
        payload: Payload,
        as _: Row.Type
    ) async throws -> Row {
        try await Supa.client.from(table.rawValue).insert(payload, returning: .minimal).execute()
        return try await Supa.client.from(table.rawValue).select().eq("id", value: id).single().execute().value
    }

    /// A brand-new trip's own `trips` row (and the `trip_members` row a
    /// server trigger creates from it) may not have finished the normal
    /// debounced-outbox round trip yet, so a share link/invite created
    /// moments after the trip itself can transiently 42501 regardless of
    /// the fix above. Retried a bounded number of times via the same
    /// exponential-with-jitter `SyncBackoff` every other retry path in this
    /// actor already uses (`SyncEngine+Push.swift`/`+Realtime.swift`) rather
    /// than a second, hand-rolled linear policy; a *persistent* 42501 still
    /// throws once the budget's spent, for the caller to surface as a
    /// failure. Internal (not `private`) so it's directly testable with a
    /// synthetic `attempt` closure — no PostgREST double needed, unlike
    /// `insertAndReadBack` itself.
    func withOrganizerRaceRetry<T>(_ attempt: () async throws -> T) async throws -> T {
        var lastError: Error = CancellationError()
        for attemptIndex in 0..<Self.maxOrganizerRaceAttempts {
            do {
                return try await attempt()
            } catch let error as PostgrestError where error.code == "42501" {
                lastError = error
                let delay = SyncBackoff.delay(attemptsSoFar: attemptIndex)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
        }
        throw lastError
    }
}
