import Foundation

/// App configuration.
///
/// These identifiers are public and safe to commit — see this repo's
/// CLAUDE.md ("Backend — lives in a different repo" / "Project identity").
/// The **publishable key** is the only Supabase key allowed to appear
/// anywhere in this repo; the **service-role key must never appear here**
/// — it bypasses row-level security. Schema and RLS changes happen only in
/// `~/repos/backend/projects/tripto`.
enum Config {
    static let SUPABASE_URL = URL(string: "https://qgtveaqukvbtyunupzhn.supabase.co")!

    // publishable key — safe to commit; service-role key must NEVER appear in this repo
    static let SUPABASE_PUBLISHABLE_KEY = "sb_publishable_4x21OrhJWtnB1tDrhD9ueA_79p98yN-"
}
