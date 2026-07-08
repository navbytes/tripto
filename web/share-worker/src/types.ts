// Shapes returned by the Supabase RPC `get_public_trip` (see
// ~/repos/backend/projects/tripto/supabase/migrations/20260707161358_tripto_core_schema.sql).
// This RPC is already sanitized server-side: no confirmation codes, no notes,
// no coordinates, no member identities. The worker never needs to (and must
// never) strip fields itself -- it only needs to render what comes back.

export interface Env {
  SUPABASE_URL: string;
  SUPABASE_PUBLISHABLE_KEY: string;
  // Optional: only set once the owner has an Apple Team ID. Absent in early
  // deploys -- the AASA route 404s until it's configured (see README).
  APPLE_TEAM_ID?: string;
}

export type ItemCategory = "flight" | "hotel" | "activity" | "food";

export interface PublicTripItem {
  category: ItemCategory;
  title: string;
  starts_at: string; // ISO 8601 UTC instant
  ends_at: string | null;
  tz: string; // IANA tz of the item's location
  location_name: string;
  status: "confirmed"; // get_public_trip only ever returns confirmed items
}

export interface PublicTripSummary {
  title: string;
  destination: string;
  country_code: string;
  start_date: string; // date, "YYYY-MM-DD"
  end_date: string; // date, "YYYY-MM-DD"
  cover_gradient: string;
}

export interface PublicTripPayload {
  trip: PublicTripSummary;
  items: PublicTripItem[];
}
