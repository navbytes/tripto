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
        supabaseKey: Config.SUPABASE_PUBLISHABLE_KEY
    )
}
