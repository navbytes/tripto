# tripto-email

EI-3 (`docs/EMAIL_IMPORT_PLAN.md`): the Cloudflare Email Worker that receives
mail forwarded to a trip's import address and hands it off to the
`ingest-email` Supabase edge function (EI-1, `~/repos/backend/projects/tripto/functions/ingest-email/`),
which does the actual parsing/LLM work and writes `'suggested'` itinerary
items. This Worker stays deliberately "dumb," per the plan's decision table:
no LLM call, no DB access, no service-role key -- it only extracts the trip
token, parses the MIME message, and relays plain fields over HTTPS with a
shared secret.

## What it does

1. Cloudflare Email Routing delivers mail addressed to
   `t-<token>@plans.tripto.navbytes.io` to this Worker's `email()` handler
   (`ForwardableEmailMessage`, the standard Cloudflare Email Worker
   interface -- see `@cloudflare/workers-types`).
2. **Token extraction** (`src/token.ts`): pulls `<token>` out of the
   *envelope* recipient (`message.to`), not a header -- headers are
   sender-controlled and trivially spoofed; the envelope-to is what Cloudflare
   Email Routing actually delivered to. An address that doesn't match
   `t-<token>@...` gets `message.setReject(...)` -- a clean bounce, same as a
   real mail server rejecting an unknown mailbox, so the sender finds out
   immediately instead of the email silently vanishing.
3. **MIME parsing** (`src/index.ts` + `postal-mime`): `message.raw` (a
   `ReadableStream<Uint8Array>`) is parsed with
   [`postal-mime`](https://github.com/postalsys/postal-mime) into `From`,
   `Subject`, plain-text body, and HTML body.
4. **Relay** (`src/ingest.ts`): POSTs
   `{ token, from, subject, text, html }` to
   `https://qgtveaqukvbtyunupzhn.supabase.co/functions/v1/ingest-email` with
   header `X-Ingest-Secret: <EMAIL_INGEST_SHARED_SECRET>`.

### Why `postal-mime`

Cloudflare Email Workers give you raw MIME bytes and nothing else -- no
Node.js APIs are available in the Workers runtime, which rules out most
mail-parsing libraries (they assume Node's `Buffer`/streams). `postal-mime`
is a small, dependency-free (`deps: none`), pure-JS/WHATWG-streams parser
built for exactly this (browser + Workers + Node), and it accepts a
`ReadableStream` directly -- `PostalMime.parse(message.raw)` needs no
adapter. It's also the parser Cloudflare's own Email Workers examples point
to. No fragile hand-rolled MIME parsing here.

## Failure modes

Cloudflare Email Workers have **no "retry later" primitive** -- once
`email()` returns, that inbound message is done, one way or another. That
constraint drives every failure decision below; there is no way to make a
transient backend hiccup transparently retry, so this Worker picks the
least-surprising behavior for each case instead of pretending it's handled:

| Situation | Behavior | Why |
|---|---|---|
| Recipient address doesn't resolve to a token (bad prefix, non-hex token, no `@`) | `message.setReject("No such mailbox.")` -- a clean SMTP-level bounce | Matches how a real mail server responds to an unknown mailbox. The sender finds out immediately (most forwarders/clients surface a bounce), rather than the email vanishing with no signal at all. |
| MIME body fails to parse (`PostalMime.parse` throws) | Silently dropped, one log line, no raw error/content | The address was valid, so this isn't the sender's fault in any way we can name confidently (could just be a mail client that's slightly off-spec) -- rejecting would bounce ordinary, legitimate mail. |
| POST to `ingest-email` throws (network error) or returns non-2xx | Silently dropped, one log line with the status code only | Could be a transient Supabase/network blip, a misconfigured secret, or `ingest-email` itself being down -- none of that is the sender's fault, and there's no retry primitive to fall back on. Bouncing a real family member's forwarded flight confirmation because of *our* backend problem would be far more confusing than a silent drop. This is a real gap (a message can be lost with only a log line as evidence) -- EI-4 (hardening, not yet built) is the place to revisit it, e.g. surfacing failed-post counts somewhere the owner actually looks. |

`ingest-email` itself already returns `200`/`202` for anything that isn't a
genuine internal error (unknown token, rate-limited, low-confidence parse,
LLM failure -- see its own comments) specifically so this Worker doesn't need
to distinguish those cases; a non-2xx from it means something is
infrastructurally wrong (bad secret, DB write failure, `ingest-email` down),
which is exactly the "log and drop" case above.

## No PII/secrets in logs

Matches `share-worker`'s discipline (no `console.log` of tokens/URLs
anywhere in its `src/`): this Worker never logs the email body (text/html),
the `Subject` (can echo booking confirmation codes), the `From` address, the
trip token, or `EMAIL_INGEST_SHARED_SECRET`. The only log lines are the fixed
strings in `src/index.ts` (a parse-failure notice, or an ingest failure with
just an HTTP status code) -- grep `console\.` in `src/` to confirm nothing
new violates this.

## Local checks (no live Cloudflare access needed)

```sh
cd web/email-worker
npm install
npm run typecheck   # tsc --noEmit (src/) + tsc -p tsconfig.test.json --noEmit (src/*.test.ts)
npm test            # node --test src/*.test.ts
```

`npm test` runs `src/token.test.ts` (address -> token extraction, including
malformed/edge cases) and `src/ingest.test.ts` (MIME parsing of a realistic
fixture booking email through `postal-mime` into the exact `ingest-email`
JSON shape, plus `postIngest`'s ok/http_error/network_error paths against a
mocked `fetch`) -- both run against real parsing logic, not hand-waved.

`wrangler deploy --dry-run` (no `--outdir` needed, just to confirm the Worker
bundles) also succeeds locally -- it doesn't require the
`EMAIL_INGEST_SHARED_SECRET` to be set, only `wrangler deploy` (the real
deploy) does.

**Not tested here, and can't be without live Cloudflare access:** an actual
inbound email traversing Cloudflare Email Routing into this Worker,
`message.setReject`'s real bounce behavior, and the live round-trip to
`ingest-email` (that function's own contract is exercised by its own tests
in the backend repo, if any -- this repo only unit-tests the Worker's own
logic).

## Owner setup (required before this does anything)

None of the steps below can be done from this repo/agent -- they need
Cloudflare account dashboard access and a value only the owner should
generate. **Nothing in this feature works until all of these are done.**

1. **Enable Cloudflare Email Routing** for the `navbytes.io` zone, if not
   already on (Cloudflare dashboard -> the zone -> Email -> Email Routing).
   This only *adds* capability at the zone level; it does not touch the
   apex's existing iCloud+ mail (MX for `navbytes.io` / `tripto@navbytes.io`
   stays untouched -- see the DNS step below for why the new record must be
   scoped to the subdomain only).

2. **Add DNS MX (+ related) records for `plans.tripto.navbytes.io` only** --
   Cloudflare's Email Routing setup flow generates these automatically once
   you add the subdomain in the Email Routing UI; it will not offer to touch
   `navbytes.io`'s own MX records unless you explicitly point it at the
   apex, which you should not do. Double-check the generated records are
   scoped to the `plans` subdomain, not `@`/apex, before saving.

3. **Add a catch-all routing rule**: Email Routing -> Routing rules ->
   Catch-all address -> **Send to a Worker** -> `tripto-email` (this
   Worker's `wrangler.jsonc` `name`). A catch-all (not per-address rules) is
   required because trip tokens are minted dynamically -- there's no fixed
   list of addresses to route individually.

4. **Generate and set the shared secret in *both* places.** This is the one
   step most likely to be gotten wrong, so read carefully:
   - Generate one random value, e.g. `openssl rand -hex 32`.
   - Set it on the Supabase side (`ingest-email`'s env):
     ```sh
     supabase secrets set EMAIL_INGEST_SHARED_SECRET=<value> --project-ref qgtveaqukvbtyunupzhn
     ```
     (from `~/repos/backend/projects/tripto/`, per that repo's edge-function
     secret workflow.)
   - Set the **exact same value** here:
     ```sh
     cd web/email-worker
     wrangler secret put EMAIL_INGEST_SHARED_SECRET
     ```
   - **Neither side has this secret set yet** (as of EI-3 landing) --
     `ingest-email` currently rejects every request with `401` until this is
     done on both sides. If the two values ever drift (e.g. one side gets
     rotated without the other), every inbound email will silently fail the
     "log and drop" path above with `ingest-email rejected the message
     (status 401)` -- check Worker logs (`wrangler tail`) first if imports
     stop working.

5. **Deploy the Worker**:
   ```sh
   cd web/email-worker
   npm install
   wrangler deploy
   ```

6. **Verify end-to-end**: open a trip's Add-Item screen in the app (EI-2's
   real import address, replacing the old waitlist stub), forward a real
   booking confirmation email to the shown `t-<token>@plans.tripto.navbytes.io`
   address, and confirm a `'suggested'` item shows up in that trip's review
   inbox within a minute or two. `wrangler tail` (from this directory) shows
   this Worker's live logs if something doesn't show up.

## Notes for whoever touches this next

- No `fetch()` handler, no `routes`, `workers_dev: false` in
  `wrangler.jsonc` -- this Worker has no HTTP surface at all. The only way
  in is inbound email via the catch-all rule above.
- No `send_email` binding -- that binding is only for *composing/sending*
  mail from a Worker (forward/reply/new message). This Worker never does
  that; it only relays parsed fields over a plain `fetch`.
- `src/index.ts` is kept thin on purpose: token extraction (`src/token.ts`)
  and payload building/posting (`src/ingest.ts`) are pure/testable functions
  with no Workers-runtime-only APIs, so they can run under plain `node --test`
  without any Workers simulation. `src/index.ts` itself (the actual
  `email()` handler wiring) is the one piece that can't be unit-tested this
  way and is exercised only by the dry-run bundle check above.
- The `t-<token>@plans.tripto.navbytes.io` address format and the
  `{ token, from, subject, text, html }` / `X-Ingest-Secret` contract are
  both pinned by `ingest-email`'s own code
  (`~/repos/backend/projects/tripto/functions/ingest-email/index.ts`) --
  if that contract ever changes, update `src/types.ts`'s `IngestPayload` and
  `src/ingest.ts` together with it.
