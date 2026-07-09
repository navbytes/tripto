# Email import & universal links — implementation plan

Companion to `RELEASE_READINESS.md`. Covers the two features scoped in that
doc's §8 risks / §0.5 step 4: real email-import parsing (replacing the
waitlist stub) and universal links (currently deferred pending an Apple
capability). Same status keys: ✅ done · 🔄 in progress · ⏳ queued (I can do
it) · 🔑 **owner-only**.

Last updated: 2026-07-09 (EI-0 through EI-3 done; LLM routing moved to Cloudflare AI Gateway).

---

## Feature 1 — Email import (full auto-parse)

### What already exists (building with the grain)

- `itinerary_items.status` (`'suggested' | 'confirmed'`) already exists in
  the schema and in Swift (`ItemStatus`), added for exactly this purpose
  (BUILD_PLAN §5.6) but nothing writes `'suggested'` today.
- **Not yet true, must become true before this ships:** the timeline is not
  status-aware — `TripView`'s item query and `BookingsTabView`'s feed don't
  filter on `status` at all. A suggested row would render on the trusted
  family timeline today with zero visual distinction. This is EI-2, and it
  gates EI-3 (see rollout).
- `get_public_trip` already filters `status = 'confirmed'`, so suggested
  items never leak to the public share page — nothing to change there.
- Suggested rows sync down for free via the existing realtime publication
  and per-member SELECT policy — no new sync code needed.
- The review-and-confirm UI is an *edit* of a suggested row through the
  existing `AddItemSheet` (already takes `editing: ItineraryItem?` with full
  per-category forms) — not a new form.
- Two existing backend patterns to copy: `apple_refresh_tokens` (edge-only
  table, zero RLS policies = service-role-only) and `apple-link-token`
  (edge function holding a secret, never exposed to the client). The
  service-role key must never enter the tripto app repo — this drives the
  whole topology below.

### Decisions

| Decision | Choice | Why |
|---|---|---|
| Email receiving | **Cloudflare Email Routing → a new Email Worker** | Same platform as the existing `share-worker`; no public HTTP endpoint to secure (unlike an inbound webhook from SendGrid/Mailgun); no new vendor. |
| MX | **Dedicated subdomain `plans.tripto.navbytes.io`** | `tripto@navbytes.io`'s MX is iCloud+ mail today — must not hijack the apex. |
| Addressing | **One token per trip**: `t-<token>@plans.tripto.navbytes.io`, shown/copyable on the Add-Item screen | Unambiguous routing — the token *is* the trip. Rejected per-user "current trip" heuristics (fragile with overlapping trips) and shared-address-with-sender-matching-for-routing (`From` is trivially spoofed). |
| Where the LLM call happens | **A new Supabase edge function (`ingest-email`)**, not the Cloudflare Worker | The privileged DB write already has to live in an edge function (service role can't be in this repo); putting the LLM call there too keeps both the service-role key and any provider credentials out of the app repo. The Worker stays "dumb": parse MIME, extract token/From/Subject/body, POST to the edge function with a shared secret. |
| **LLM routing & billing** | **Cloudflare AI Gateway's unified REST API** (`api.cloudflare.com/.../ai/v1/chat/completions`), not a direct call to Anthropic's API | OpenAI-compatible tool-calling that Gateway translates to whichever provider is configured — `LLM_MODEL` is a plain `"{provider}/{model}"` config string (`anthropic/claude-haiku-4-5` today), so switching to Sonnet or a different provider (Gemini, etc.) later is a secret value change, not a code change. Auth is a single Cloudflare API token via **Unified Billing** (one Cloudflare bill covers whichever provider is in use, pass-through per-token pricing, no per-provider key to manage) — replaces the originally-planned `ANTHROPIC_API_KEY` secret entirely. |
| **Default model** | **`anthropic/claude-haiku-4-5`** | Bounded structured-extraction task, not open-ended reasoning — cheapest capable tier is the right default, and Haiku is on Anthropic's officially-supported structured-output model list. The confidence-gate/review-inbox safety net absorbs the accuracy tradeoff vs. a larger model. |
| **Confidence threshold** | **Balanced** — suggest whenever reasonably confident it's a real booking | Nothing auto-confirms; a human always reviews. A wrong suggestion costs one dismiss tap; a missed real booking defeats the feature. Errs toward catching more. |
| **Raw email retention** | **7 days**, then purge `raw_text`/`raw_html` (keep metadata for audit) | Matches the app's existing minimal-retention, no-tracking posture. Tighter than typical — means the reprocess-after-a-prompt-fix window is short; design EI-1 so low-confidence/rejected rows are easy to act on quickly rather than assuming a long runway. |
| **Who can confirm/dismiss a suggested item** | **Any companion or organizer** | The review inbox is a shared triage queue for the whole trip, not gated to whoever forwarded the original email — matches how families actually split "who forwards vs. who cleans up." |
| Containment against abuse | `status='suggested'` alone is sufficient — a human must always confirm | Rate-limiting and an "unverified sender" flag are added on top for cost/spam control, not as the safety boundary. |

### Data model (backend repo migrations)

- **`trip_import_addresses`**: `id, trip_id fk, token unique default encode(gen_random_bytes(16),'hex'), revoked bool, created_at`. Mirrors `share_links`. RLS: SELECT for any trip member, INSERT/rotate organizer-only.
- **`email_imports`** (landing/audit): `id, trip_id, token_used, from_email, subject, raw_text, raw_html, received_at, status (received|parsed|low_confidence|rejected|failed), parse_confidence, parsed_json jsonb, model, error, created_item_ids uuid[]`. RLS: deny-all, edge-function-only (raw emails carry PII/confirmation codes). A daily cron nulls `raw_text`/`raw_html` after 7 days; metadata (status, confidence, subject, timestamps) persists for audit.
- **`itinerary_items`** gets two new columns: `source text not null default 'manual' check in ('manual','email_import')` and `email_import_id uuid null`.
- Insert path: `ingest-email` writes via service role with `status='suggested'`, `source='email_import'`, `created_by` = the sender's profile if `from_email` matches a trip member, else the trip's organizer (satisfies the existing FK; confirm permission itself is NOT gated by this — see decisions table).

### App-side changes

- `TripView`'s item `@Query` and `BookingsTabView`'s feed: add a `confirmed`-only filter so suggested items leave the trusted itinerary/bookings views until reviewed.
- A review banner (clone of `SyncIssueBanner`'s pattern, amber/sky treatment) on the Itinerary tab: "N imported bookings to review" → opens a list of the trip's suggested items.
- Tapping a suggested item opens `AddItemSheet` in edit mode, prefilled from the parsed data, reviewable/editable field-by-field. Saving flips `status` to `confirmed`. A "Dismiss" action deletes the suggested row and marks the source `email_imports` row rejected.
- Replace the waitlist stub (`ItineraryTabView`'s `importTeaser`) with the trip's real import address (copyable) + a one-line "how it works."

### Staged rollout

| Stage | Repo | Gate |
|---|---|---|
| **EI-0** ✅ — schema: two new tables, two new `itinerary_items` columns, RLS, an RPC to read/rotate a trip's import address, an RPC to dismiss/mark an import | backend | done, live |
| **EI-1** ✅ — `ingest-email` edge function: shared-secret auth, token→trip resolve, land raw row, LLM structured-parse via Cloudflare AI Gateway (balanced confidence gating), insert suggested item(s), rate-limit | backend | 🔑 set `CLOUDFLARE_API_TOKEN` + `CLOUDFLARE_ACCOUNT_ID` (AI Gateway Unified Billing — see below) + `EMAIL_INGEST_SHARED_SECRET`; optionally `LLM_MODEL` to override the default |
| **EI-2** ✅ — app: status-aware queries, review banner + inbox, `AddItemSheet` confirm/dismiss mode, real import address in the UI | app | done, on branch `email-import-app` ([PR #4](https://github.com/navbytes/tripto/pull/4)) |
| **EI-3** ✅ — the actual email Worker (`web/email-worker`): MIME parse, extract token/From/Subject/body, forward to `ingest-email` | app repo (Cloudflare) | code done; 🔑 owner still needs to enable Cloudflare Email Routing on `plans.tripto.navbytes.io` (DNS MX), add a catch-all rule → Worker, set the shared secret (same value as EI-1's), and `wrangler deploy` |
| **EI-4** — hardening: 7-day retention cron, reprocessing path, rate-limit tests, unverified-sender UX | both | — |
| **EI-5** (deferred to v1.1) — push notifications on suggested-item insert | both | 🔑 APNs key |

Dependency order: **EI-0 → (EI-1 ∥ EI-2) → EI-2 gates EI-3 → EI-4**. All satisfied.

**Remaining before this is live end-to-end (all owner steps, nothing left to build):**
1. 🔑 Load Unified Billing credits in the Cloudflare dashboard (AI Gateway → Credits Available → top up) — this is what actually pays for LLM calls; no Anthropic/Gemini account needed.
2. 🔑 Create a Cloudflare API token with `AI Gateway Run` permission; set it as `CLOUDFLARE_API_TOKEN` and the account ID as `CLOUDFLARE_ACCOUNT_ID` on the `ingest-email` function (`supabase secrets set ...`).
3. 🔑 Generate one shared-secret value; set it as `EMAIL_INGEST_SHARED_SECRET` on both `ingest-email` (Supabase) and the email Worker (`wrangler secret put`) — must match exactly.
4. 🔑 Enable Cloudflare Email Routing on `navbytes.io`, DNS MX scoped to the `plans` subdomain only, catch-all rule → the email Worker, then `wrangler deploy` from `web/email-worker`.

---

## Feature 2 — Universal links

More done already than it first looked: the AASA is live and correct, the
app already parses the universal-link URL shape, and the signing team is
already pinned in `project.yml`. The only missing piece is the entitlement
itself, deliberately withheld until the App ID capability is enabled
(adding it earlier makes archiving fail).

1. 🔑 **Owner** — Apple Developer console → App ID `io.navbytes.tripto` →
   enable **Associated Domains** (same console as Sign in with Apple).
2. ⏳ Add `com.apple.developer.associated-domains: ["applinks:tripto.navbytes.io"]`
   to `project.yml`, `xcodegen generate`. The only code change, ready the
   moment step 1 lands.
3. ✅ AASA already verified correct (`59J9RQXYYP.io.navbytes.tripto`,
   `paths: ["/join/*"]`) — no redeploy needed.
4. 🔑 **Owner** — on a signed device build, confirm tapping a
   `https://tripto.navbytes.io/join/<token>` link opens the app directly.

`tripto://` custom-scheme invites already work today via the web `/join`
page's "Open in Tripto" button — this is additive polish (removes one tap),
not a blocker.

**Minor cleanups while touching this:** `web/share-worker/README.md`'s
example paths and `project.yml`'s stale "TODO once it does" comment (the
signing team is already set) should be corrected in the same pass.

---

## Load-bearing files

**App** (`/Users/naveen/repos/tripto`)
- `Tripto/Sources/Features/Trip/TripView.swift` — item query, needs the confirmed-only filter.
- `Tripto/Sources/Features/Trip/AddItemSheet.swift` — `save()`, needs suggested→confirmed flip + dismiss.
- `Tripto/Sources/Features/Trip/ItineraryTabView.swift` — `importTeaser`, the waitlist stub to replace.
- `Tripto/Sources/Design/Components/SyncIssueBanner.swift` — pattern to clone for the review banner.
- `Tripto/Sources/Models/Enums.swift` — `ItemStatus` (already present).
- `Tripto/Sources/Support/DeepLink.swift` — already handles the universal-link `/join` shape, no change needed.
- `project.yml` — add the associated-domains entitlement once unblocked.
- `web/share-worker/src/index.ts` — AASA (already correct); `web/email-worker/` is new.

**Backend** (`~/repos/backend/projects/tripto`)
- `supabase/migrations/20260707161358_tripto_core_schema.sql` — `status` column, item RLS, public-read filter (reference).
- `supabase/migrations/20260708074827_tripto_apple_refresh_tokens.sql` — deny-all edge-only table pattern to copy for `email_imports`.
- `functions/apple-link-token/index.ts` — edge-function + secret pattern to copy for `ingest-email`.
- `functions/ingest-email/index.ts` — the parse/insert function; its `callLLM()` is the Cloudflare AI Gateway call, `DEFAULT_LLM_MODEL` the fallback model string.
- `supabase/migrations/<ts>_tripto_email_import.sql` — EI-0 schema.
