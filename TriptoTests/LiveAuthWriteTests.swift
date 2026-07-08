import XCTest
import Supabase
@testable import Tripto

/// Live integration test against the real Supabase backend, using the app's
/// actual `Supa.client`. Gated behind TRIPTO_LIVE_TESTS=1 so the normal
/// (hermetic) suite never hits the network or mutates the backend.
///
/// Purpose: settle definitively whether a freshly-signed-in anonymous session
/// can perform an authenticated write through `Supa.client` — i.e. whether the
/// session token propagates to PostgREST requests. (M3's drill reported it does
/// not; the live data and this test say it does.)
final class LiveAuthWriteTests: XCTestCase {
    private struct TripInsert: Encodable {
        let id: UUID
        let title: String
        let startDate: String   // -> start_date via the client's snake_case encoder
        let endDate: String     // -> end_date
        let createdBy: UUID     // -> created_by
    }

    private struct TripRow: Decodable {
        let id: UUID
        let title: String
    }

    func testFreshAnonymousSessionWritesThroughSupaClient() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TRIPTO_LIVE_TESTS"] == "1",
            "Live backend test — set TRIPTO_LIVE_TESTS=1 to run."
        )

        // 1. Sign in anonymously via the real app client.
        let session = try await Supa.client.auth.signInAnonymously()
        let uid = session.user.id

        // DIAGNOSTICS — where is the token at write time?
        let signInTok = String(session.accessToken.prefix(10))
        let currentTok = Supa.client.auth.currentSession.map { String($0.accessToken.prefix(10)) } ?? "NIL"
        let awaited = try? await Supa.client.auth.session
        let awaitedTok = awaited.map { String($0.accessToken.prefix(10)) } ?? "NIL"
        print("DIAG signIn=\(signInTok) currentSession=\(currentTok) awaitedSession=\(awaitedTok)")

        // 2. Attempt the authenticated write AFTER force-awaiting the session
        //    (probe: does ensuring the session is loaded make the token attach?).
        let id = UUID()
        let row = TripInsert(
            id: id, title: "LiveAuthWriteTest",
            startDate: "2026-09-01", endDate: "2026-09-03", createdBy: uid
        )
        do {
            try await Supa.client.from("trips").insert(row, returning: .minimal).execute()
            print("DIAG insert=SUCCEEDED")
        } catch {
            print("DIAG insert=FAILED \(error)")
            XCTFail("Authenticated insert failed for a fresh anonymous session — "
                    + "session token did NOT propagate: \(error)")
            throw error
        }

        // 3. Read it back through the same client (proves the token is attached
        //    to reads too, and the organizer-membership trigger fired so
        //    trips_select returns the row).
        let fetched: [TripRow] = try await Supa.client
            .from("trips").select("id,title").eq("id", value: id).execute().value
        XCTAssertEqual(fetched.first?.title, "LiveAuthWriteTest",
                       "Row not readable back — write did not reach the server.")

        // 4. Clean up: delete_account cascades the trip + membership away, so
        //    this test leaves no residue on the backend.
        _ = try? await Supa.client.rpc("delete_account").execute()
    }

    private struct InviteInsert: Encodable {
        let id: UUID
        let tripId: UUID
        let role: String
        let createdBy: UUID
    }
    private struct InviteRow: Decodable { let token: String }
    private struct MemberRow: Decodable { let role: String }
    private struct ClaimParams: Encodable { let inviteToken: String }

    /// End-to-end proof of M3's collaboration flow against the live backend,
    /// signed (so Keychain persists each session): organizer A creates a trip
    /// + companion invite; user B claims the token and becomes a companion
    /// member who can read the trip. This is the flow M3's drill couldn't
    /// complete on an unsigned build.
    func testInviteClaimFlowAcrossTwoUsers() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TRIPTO_LIVE_TESTS"] == "1",
            "Live backend test — set TRIPTO_LIVE_TESTS=1 to run."
        )

        // Organizer A creates a trip (trigger seats A as organizer).
        let a = try await Supa.client.auth.signInAnonymously()
        let tripId = UUID()
        try await Supa.client.from("trips").insert(
            TripInsert(id: tripId, title: "InviteClaimTest",
                       startDate: "2026-09-01", endDate: "2026-09-03", createdBy: a.user.id),
            returning: .minimal
        ).execute()

        // A mints a companion invite and reads its server-generated token.
        let inviteId = UUID()
        try await Supa.client.from("invites").insert(
            InviteInsert(id: inviteId, tripId: tripId, role: "companion", createdBy: a.user.id),
            returning: .minimal
        ).execute()
        let invites: [InviteRow] = try await Supa.client
            .from("invites").select("token").eq("id", value: inviteId).execute().value
        let token = try XCTUnwrap(invites.first?.token, "invite token not readable by organizer")

        // Switch to a fresh user B and claim.
        try await Supa.client.auth.signOut()
        let b = try await Supa.client.auth.signInAnonymously()
        let claimed: UUID = try await Supa.rpc("claim_invite", params: ClaimParams(inviteToken: token))
        XCTAssertEqual(claimed, tripId, "claim_invite returned the wrong trip id")

        // B is now a companion member and can read the shared trip.
        let members: [MemberRow] = try await Supa.client
            .from("trip_members").select("role")
            .eq("trip_id", value: tripId).eq("user_id", value: b.user.id).execute().value
        XCTAssertEqual(members.first?.role, "companion", "B did not become a companion member")
        let trips: [TripRow] = try await Supa.client
            .from("trips").select("id,title").eq("id", value: tripId).execute().value
        XCTAssertEqual(trips.first?.title, "InviteClaimTest", "B cannot read the joined trip")

        // Cleanup: B removes itself; A's throwaway trip is swept separately.
        _ = try? await Supa.client.rpc("delete_account").execute()
    }

    private struct ItemInsert: Encodable {
        let id: UUID
        let tripId: UUID
        let category: String
        let title: String
        let startsAt: String
        let tz: String
        let createdBy: UUID
    }
    private struct TripProfileInsert: Encodable {
        let id: UUID
        let tripId: UUID
        let displayName: String
    }
    private struct AssigneeInsert: Encodable {
        let itemId: UUID
        let profileId: UUID
    }
    private struct AssigneeRow: Decodable {
        let itemId: UUID
        let profileId: UUID
    }

    /// M4: proves the composite-key (`item_id`, `profile_id`) delete
    /// `SyncEngine+Push.pushDelete`'s `.itemAssignees` branch special-cases
    /// actually works against the live backend — `item_assignees` has no
    /// surrogate `id` column (confirmed live via `list_tables`), so this is
    /// the one mirrored table where every other table's plain
    /// `.eq("id", value: rowId)` delete shape would be wrong (`column "id"
    /// does not exist`). Reuses this file's harness/gating per this
    /// milestone's CRITICAL verification rule: signed build required (an
    /// authenticated write), `TRIPTO_LIVE_TESTS=1` to run.
    func testItemAssigneeCompositeKeyInsertAndDelete() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["TRIPTO_LIVE_TESTS"] == "1",
            "Live backend test — set TRIPTO_LIVE_TESTS=1 to run."
        )

        let session = try await Supa.client.auth.signInAnonymously()
        let uid = session.user.id

        let tripId = UUID()
        try await Supa.client.from("trips").insert(
            TripInsert(
                id: tripId, title: "ItemAssigneeCompositeKeyTest",
                startDate: "2026-09-01", endDate: "2026-09-03", createdBy: uid
            ),
            returning: .minimal
        ).execute()

        let itemId = UUID()
        try await Supa.client.from("itinerary_items").insert(
            ItemInsert(
                id: itemId, tripId: tripId, category: "activity", title: "Composite key test item",
                startsAt: "2026-09-01T10:00:00Z", tz: "UTC", createdBy: uid
            ),
            returning: .minimal
        ).execute()

        let profileId = UUID()
        try await Supa.client.from("trip_profiles").insert(
            TripProfileInsert(id: profileId, tripId: tripId, displayName: "Composite Test Profile"),
            returning: .minimal
        ).execute()

        // Insert the assignment — the exact shape `pushUpsert`'s plain-insert
        // path issues (no `.upsert()`, see that method's doc comment).
        try await Supa.client.from("item_assignees").insert(
            AssigneeInsert(itemId: itemId, profileId: profileId), returning: .minimal
        ).execute()

        var rows: [AssigneeRow] = try await Supa.client.from("item_assignees").select()
            .eq("item_id", value: itemId).eq("profile_id", value: profileId).execute().value
        XCTAssertEqual(rows.count, 1, "assignment did not reach the server")

        // Delete by the composite key — the exact shape
        // `SyncEngine+Push.pushDelete`'s `.itemAssignees` branch issues.
        try await Supa.client.from("item_assignees").delete()
            .eq("item_id", value: itemId).eq("profile_id", value: profileId).execute()

        rows = try await Supa.client.from("item_assignees").select()
            .eq("item_id", value: itemId).eq("profile_id", value: profileId).execute().value
        XCTAssertTrue(rows.isEmpty, "composite-key delete did not remove the row server-side")

        _ = try? await Supa.client.rpc("delete_account").execute()
    }
}
