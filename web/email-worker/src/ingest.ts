import type { Email } from "postal-mime";
import type { Env, IngestPayload } from "./types";

/**
 * "Jane Doe <jane@example.com>" when a display name is present, else the
 * bare address -- the shape `ingest-email`'s `extractEmail()` (backend repo,
 * functions/ingest-email/index.ts) already parses. Falls back to the raw
 * `From` header on the rare malformed message postal-mime couldn't resolve
 * an address out of (e.g. a header postal-mime treats as a group, not a
 * mailbox).
 */
export function formatFrom(parsed: Pick<Email, "from">, rawFromHeader: string | null): string {
  const from = parsed.from;
  const address = from && typeof from.address === "string" ? from.address : null;
  if (address) {
    return from?.name ? `${from.name} <${address}>` : address;
  }
  return rawFromHeader ?? "";
}

/**
 * Builds the exact JSON body `ingest-email` expects (EMAIL_IMPORT_PLAN.md,
 * EI-3): token + From + Subject + both body variants. Pure and testable --
 * no network calls, no Workers-runtime-only APIs (see src/ingest.test.ts).
 */
export function buildIngestPayload(
  token: string,
  parsed: Pick<Email, "from" | "subject" | "text" | "html">,
  rawFromHeader: string | null,
): IngestPayload {
  return {
    token,
    from: formatFrom(parsed, rawFromHeader),
    subject: parsed.subject ?? "",
    text: parsed.text ?? "",
    html: parsed.html ?? null,
  };
}

export type PostIngestResult =
  | { ok: true }
  | { ok: false; reason: "http_error"; status: number }
  | { ok: false; reason: "network_error" };

/**
 * POSTs to `ingest-email` with the shared-secret header. Never throws --
 * failure comes back as a result so the caller (src/index.ts) can pick the
 * (silent-drop) failure mode. See README "Failure modes" for why this
 * Worker never retries or bounces on a transient POST failure: Cloudflare
 * Email Workers have no retry-later primitive, and bouncing a legitimate
 * sender for a problem on our side would be more confusing than a drop.
 */
export async function postIngest(env: Env, payload: IngestPayload): Promise<PostIngestResult> {
  let resp: Response;
  try {
    resp = await fetch(env.INGEST_EMAIL_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-Ingest-Secret": env.EMAIL_INGEST_SHARED_SECRET,
      },
      body: JSON.stringify(payload),
    });
  } catch {
    return { ok: false, reason: "network_error" };
  }

  if (!resp.ok) {
    return { ok: false, reason: "http_error", status: resp.status };
  }
  return { ok: true };
}
