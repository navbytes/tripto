import Foundation
import Supabase

/// Shared Supabase client singleton, built from `Config`.
///
/// Auth is Sign in with Apple through Supabase Auth (BUILD_PLAN.md §3.5).
/// Every table is RLS deny-by-default (CLAUDE.md "Security model the app
/// must assume") — the three trip roles (organizer/companion/viewer) are
/// enforced server-side by the backend repo's policies, never by client
/// checks. If a query returns no rows unexpectedly, that's almost always a
/// missing/incorrect RLS policy in `~/repos/backend`, not an app bug.
enum Supa {
    static let client = SupabaseClient(
        supabaseURL: Config.SUPABASE_URL,
        supabaseKey: Config.SUPABASE_PUBLISHABLE_KEY,
        options: SupabaseClientOptions(
            // Every request/response body goes through the same snake_case +
            // ISO8601 mechanism as the rest of the app (Models/JSONCoding.swift)
            // — DTOs are plain camelCase structs with no per-field CodingKeys.
            db: .init(encoder: JSONCoding.encoder, decoder: JSONCoding.decoder)
        )
    )

    /// Typed RPC helper (SYNC_DESIGN.md: "the sync layer should expose a
    /// typed `rpc` helper for later milestones"). No M1 screen calls an RPC
    /// yet, but `claim_invite`/`get_public_trip`/`delete_account` are already
    /// live on the backend (see the M1 brief) — this is the one seam every
    /// future call goes through, decoded via the same `JSONCoding` decoder
    /// as everything else.
    static func rpc<Params: Encodable, Response: Decodable>(
        _ function: String,
        params: Params
    ) async throws -> Response {
        try await client.rpc(function, params: params).execute().value
    }

    /// Overload for parameterless RPCs (e.g. `delete_account()`).
    static func rpc<Response: Decodable>(_ function: String) async throws -> Response {
        try await client.rpc(function).execute().value
    }
}
