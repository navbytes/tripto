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
            db: .init(encoder: JSONCoding.encoder, decoder: JSONCoding.decoder),
            // Opting into supabase-swift's post-2.50 default early (currently
            // opt-in, becomes the only behavior next major version — see
            // https://github.com/supabase/supabase-swift/pull/822): emit the
            // locally stored session immediately as `.initialSession`, even if
            // expired, instead of trying to refresh it first. AuthManager's
            // `.initialSession` handler checks `session.isExpired` per the
            // SDK's own guidance for this flag.
            auth: .init(emitLocalSessionAsInitialSession: true)
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

    /// Overload for parameterless RPCs.
    static func rpc<Response: Decodable>(_ function: String) async throws -> Response {
        try await client.rpc(function).execute().value
    }

    /// Void-returning RPC overload — `delete_account()` responds `204 No
    /// Content` with an empty body (M3 brief: "VERIFIED (HTTP 204)"), so
    /// there's nothing for a generic `Decodable` `Response` to decode.
    /// Mirrors `SyncEngine+Push.swift`'s own `.execute()`-without-`.value`
    /// pattern: still throws on a non-2xx response, just discards the body.
    static func rpcVoid(_ function: String) async throws {
        _ = try await client.rpc(function).execute()
    }

    /// Void-returning overload with params — EI-2's `dismiss_email_import_item`
    /// (`docs/EMAIL_IMPORT_PLAN.md`), same "204 No Content, nothing to
    /// decode" shape as `delete_account()` above, but taking an argument.
    static func rpcVoid<Params: Encodable>(_ function: String, params: Params) async throws {
        _ = try await client.rpc(function, params: params).execute()
    }

    /// Typed Edge Function invoke helper (TI-2, `docs/BUILD_PLAN.md`:
    /// paste-to-import calling `ingest-text`) — the same "one seam every
    /// future call goes through" role `rpc` plays above, but for Supabase
    /// Edge Functions rather than Postgres RPCs.
    ///
    /// Deliberately does **not** route through `JSONCoding.encoder`/
    /// `.decoder` (every other network body in this app's one casing/date
    /// mechanism, per that enum's doc comment) — a PostgREST row genuinely
    /// is snake_case, but an Edge Function's request/response body is
    /// whatever that function's own handler happens to read/write, and
    /// `ingest-text` reads plain camelCase JSON (`{ tripId, rawText, kind }`)
    /// straight off `req.json()`. `FunctionInvokeOptions(body:)`'s own
    /// default `JSONEncoder()` (no key strategy) is what makes a Swift
    /// `tripId` property encode as literal `"tripId"`, matching that
    /// contract; `client.functions.decoder` (also left at its own plain
    /// default, never touched by this file) does the same on the way back
    /// for a response like `{ created: 1 }`.
    ///
    /// Throws `FunctionsError.httpError(code:data:)` on a non-2xx response
    /// (`data` is the raw response body, typically `{"error":"..."}` for
    /// this app's own functions) or `.relayError` on a gateway relay
    /// failure — see the supabase-swift SDK's `Functions/Types.swift`.
    /// Callers that need a friendly per-status message decode `data`
    /// themselves (e.g. `PasteImportSheet`'s `friendlyMessage(for:)`)
    /// rather than surfacing this raw error to the user.
    static func invoke<Params: Encodable, Response: Decodable>(
        _ function: String,
        params: Params
    ) async throws -> Response {
        try await client.functions.invoke(function, options: FunctionInvokeOptions(body: params))
    }
}
