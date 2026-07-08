import type { Env, PublicTripPayload } from "./types";

export type PublicTripResult =
  | { ok: true; data: PublicTripPayload }
  | { ok: false; reason: "invalid_link" | "upstream_error" };

/**
 * Calls the sanitizing RPC (get_public_trip, SECURITY DEFINER in the backend
 * repo's tripto_core_schema migration). It already strips confirmation
 * codes, notes, coordinates, and member identities -- this function's only
 * job is to relay its result or its "invalid_link" failure.
 *
 * Never log the token or the request URL here (CLAUDE.md hard rule).
 */
export async function fetchPublicTrip(env: Env, token: string): Promise<PublicTripResult> {
  let resp: Response;
  try {
    resp = await fetch(`${env.SUPABASE_URL}/rest/v1/rpc/get_public_trip`, {
      method: "POST",
      headers: {
        apikey: env.SUPABASE_PUBLISHABLE_KEY,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ share_token: token }),
    });
  } catch {
    return { ok: false, reason: "upstream_error" };
  }

  if (resp.status === 400) {
    // plpgsql `raise exception 'invalid_link'` surfaces through PostgREST as
    // a 400 with that message -- missing or revoked token.
    return { ok: false, reason: "invalid_link" };
  }

  if (!resp.ok) {
    return { ok: false, reason: "upstream_error" };
  }

  const data = (await resp.json()) as PublicTripPayload;
  return { ok: true, data };
}
