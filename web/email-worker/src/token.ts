/**
 * Token shape mirrors `trip_import_addresses.token`
 * (`encode(gen_random_bytes(16),'hex')` = 32 lowercase hex chars), with the
 * same slack share-worker's SHARE_TOKEN_PATTERN gives `share_links.token` --
 * a future token-length change on the backend shouldn't require touching
 * this Worker too.
 */
export const IMPORT_TOKEN_PATTERN = /^[a-f0-9]{16,64}$/;

/**
 * Extracts the trip import token from the *envelope* recipient address --
 * "t-<token>@plans.tripto.navbytes.io" -> "<token>" -- per
 * EMAIL_IMPORT_PLAN.md's addressing scheme (the token *is* the trip). Reads
 * `ForwardableEmailMessage.to`, the envelope-to Cloudflare Email Routing
 * actually delivered to -- never a `To`/`Delivered-To` header, which is
 * sender-controlled and trivially spoofed.
 *
 * Returns null for anything that doesn't look like a real import address:
 * no "t-" local-part prefix, or a token that isn't hex -- both are treated
 * as "unrecognized mailbox" by the caller (src/index.ts), same as a real
 * mail server rejecting an unknown address.
 */
export function extractImportToken(envelopeTo: string): string | null {
  const at = envelopeTo.indexOf("@");
  if (at === -1) return null;

  const localPart = envelopeTo.slice(0, at).toLowerCase();
  if (!localPart.startsWith("t-")) return null;

  const token = localPart.slice(2);
  return IMPORT_TOKEN_PATTERN.test(token) ? token : null;
}
