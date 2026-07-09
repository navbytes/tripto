// tripto-email -- EI-3 (docs/EMAIL_IMPORT_PLAN.md). Receives inbound mail via
// Cloudflare Email Routing for plans.tripto.navbytes.io and relays parsed
// fields to the ingest-email edge function (EI-1, backend repo). This Worker
// is deliberately "dumb": no LLM call, no DB access, no service-role key --
// it only parses MIME and forwards, exactly per the plan's Worker/edge-
// function split.
//
// Failure modes (see README "Failure modes" for the full writeup):
//   - Recipient address doesn't resolve to a token -> reject cleanly
//     (message.setReject). The sender learns immediately, same as a real
//     mail server bouncing an unknown mailbox.
//   - MIME body fails to parse, or the POST to ingest-email fails/errors ->
//     silently drop, log only a non-PII-bearing line. Cloudflare Email
//     Workers have no retry-later primitive, and bouncing a legitimate
//     sender for a transient backend hiccup would be more confusing than a
//     drop.
//
// Never logged, anywhere in this file: the email body (text/html), the
// Subject (can echo confirmation codes), the From address, or the shared
// secret -- matches share-worker's no-token-logging discipline.

import PostalMime from "postal-mime";
import type { Env } from "./types";
import { extractImportToken } from "./token";
import { buildIngestPayload, postIngest } from "./ingest";

export default {
  async email(message: ForwardableEmailMessage, env: Env): Promise<void> {
    const token = extractImportToken(message.to);
    if (!token) {
      message.setReject("No such mailbox.");
      return;
    }

    let parsed;
    try {
      parsed = await PostalMime.parse(message.raw);
    } catch {
      console.error("email-worker: MIME parse failed for a recognized token; dropping");
      return;
    }

    const payload = buildIngestPayload(token, parsed, message.headers.get("From"));
    const result = await postIngest(env, payload);
    if (!result.ok) {
      console.error(
        result.reason === "http_error"
          ? `email-worker: ingest-email rejected the message (status ${result.status})`
          : "email-worker: ingest-email request failed (network error)",
      );
    }
  },
} satisfies ExportedHandler<Env>;
