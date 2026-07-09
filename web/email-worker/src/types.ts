export interface Env {
  // Public, safe to commit -- see wrangler.jsonc's "vars".
  INGEST_EMAIL_URL: string;
  // Secret -- set via `wrangler secret put EMAIL_INGEST_SHARED_SECRET`.
  // Must be the exact same value as the Supabase edge function's
  // `EMAIL_INGEST_SHARED_SECRET` (see README, "Owner setup").
  EMAIL_INGEST_SHARED_SECRET: string;
}

/** Exact JSON body `ingest-email` expects (backend repo,
 * functions/ingest-email/index.ts's `IngestRequestBody`). */
export interface IngestPayload {
  token: string;
  from: string;
  subject: string;
  text: string;
  html: string | null;
}
