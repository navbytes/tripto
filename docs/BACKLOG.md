# Tripto — Backlog & Deferred Items

Gaps and deferred work identified across engagements, to pick up **after the
current server-side privacy phase**. Owner-gated launch steps live in
[RELEASE_READINESS.md](RELEASE_READINESS.md) — this file is the working
backlog of things we chose to defer, not re-list.

Last updated: 2026-07-11 (added §E trip import/export evaluation; after the
server-side data-handling privacy audit).

---

## A. Email import lifecycle (do as one cluster, before email goes live)

The inbound email-import feature (EI) is partially built and **not live** (MX
not switched on). These belong together and should ship as a unit:

- **A1 — Build the EI-3 Cloudflare Email Worker.** Inbound MIME parsing +
  forwarding to the `ingest-email` edge function. Not built yet
  (`backend/projects/tripto/functions/ingest-email/index.ts` notes this).
- **A2 — Enable the email-import pipeline** (MX / routing to
  `plans.tripto.navbytes.io`). Feature-enablement, owner action.
- **A3 — [WAS F2, privacy] Automated purge of raw import emails.**
  `email_imports.raw_text/raw_html` hold raw booking emails (PII +
  confirmation codes); the intended 7-day auto-delete is comment-only
  (`migrations/20260709103528_tripto_email_import.sql:40-42`) — no cron
  exists. **HARD prerequisite before email import serves real users.** Fix:
  a `pg_cron` job nulling `raw_*` older than 7 days (pg_cron is on the free
  tier). Deferred here (not this phase) because the table is empty until A2;
  must land with A1/A2.
- **A4 — Privacy-audit the EI-3 worker once built** (what headers/metadata
  reach `ingest-email`; the shared-secret is the only auth today).
- **A5 — Explicit AI-processing consent for email import** (Apple Guideline
  5.1.2(i)). Paste-import now gates its AI send behind an explicit one-time
  consent dialog; email import uses the same LLM gateway but is triggered by a
  forwarded email, so there's no in-app send moment to gate. When email import
  ships, obtain explicit permission at the point the user enables their import
  email address (and disclose the AI processing there), or the forwarded
  content is shared with the third-party AI without consent.

## B. Cost / abuse hardening

- **B1 — [F5] Rate-limit `ingest-text`.** The paste-import edge function has
  no rate limit; each call hits the LLM (cost + abuse surface). `ingest-email`
  already limits 20/hr/token; mirror it. Do before meaningful scale.

## C. Ops & security hygiene (post-launch)

- **C1 — Secrets rotation procedure** for `EMAIL_INGEST_SHARED_SECRET` and the
  Cloudflare gateway / LLM keys (emergency revocation if a worker leaks). No
  rotation schedule today.
- **C2 — Supabase auth advisors** (low relevance while Sign-in-with-Apple is
  the only method — no passwords, Apple provides 2FA): leaked-password
  protection and additional MFA options are OFF. Revisit only if password or
  other auth methods are ever added.
- **C3 — Confirm the production LLM model actually works via Cloudflare AI
  Gateway** (`openai/gpt-4.1-mini`); `anthropic/*` is known-broken there. A
  live smoke test, not yet run.
- **C4 — Make the UI tests hermetic (durable fix for the anon-sign-in
  coupling).** Today `TriptoUITests` call the real `signInAnonymously()` via
  `-uitestAutoSignIn`, so they only pass while backend anonymous sign-in is
  enabled (see `docs/TESTING.md`), and they occasionally flake on a
  seed/auth race. Inject a fake authenticated session in the `#if DEBUG`
  `-uitestAutoSignIn` path instead; then production can keep anonymous
  sign-in off permanently and the tests stop hitting the network. Decided
  against for now (2026-07-11) — toggling the backend setting around test
  sessions is cheap enough at solo/pre-launch scale.

## D. Larger deferred product work (from BUILD_PLAN v1.5/v2)

Not started, intentionally out of v1 — listed so they aren't lost:
- Email-forward parser for the top providers (the "magic" moat, BUILD_PLAN §2).
- Real-time flight status (one aggregator API).
- Suggest-without-editing tray for companions.
- Expense tracking/splitting, document vault, maps tab, discovery.

## E. Trip import / export (evaluated 2026-07-11 — decided NOT to build generically)

"Import/export 1 or many trips" was raised as one feature; it's really four,
with very different value. Verdict: no generic import/export for v1 (launch
prep, no observed demand — YAGNI). Captured here, ranked, to pick by demand.
The tz-correct, confirmation-code-stripped `EKEvent` building already exists
per-item (`Models/CalendarEventDraft.swift` + `Features/Trip/BookingDetailView.swift`),
which is what makes E1 cheap.

- **E1 — Whole-trip Calendar export (near-term quick win).** Add the entire
  itinerary to Calendar / emit one `.ics`, vs. today's per-booking "Add to
  calendar". Mostly wiring already-tested code: loop items → `CalendarEventBuilder.draft(for:)`
  → batch `EKEvent` add, or generate a single `.ics` to share. Client-only, no
  backend, no opex. Highest value-per-effort of the four; the thing travelers
  actually mean by "export". Reuse the notes-without-confirmation-code trust
  boundary already in the draft builder.
- **E2 — "Duplicate trip" (retention hook).** Clone an existing trip as a
  template (re-run an annual trip): copy items with dates rebased, drop
  confirmation codes/bookings, keep the owner as sole member. This is the
  genuinely useful half of "import" and sidesteps the whole file-format
  problem. Cheap; local SwiftData copy + one new trip row.
- **E3 — "Download my data" export (privacy / compliance).** Dump the user's
  trips + items to JSON on request. Low functional value (already synced to
  Supabase = the real backup), but a GDPR/App-Store **data-portability trust**
  signal. Belongs with the privacy posture; do if/when a store or user asks.
  Sanitize nothing here — it's the owner's own data — but scope strictly to
  rows the requester owns (RLS already enforces this server-side).
- **E4 — PDF / printable itinerary (low priority, likely redundant).** The
  public share link (§5.2) already gives a no-app, read-only view for
  grandparents; a PDF adds offline-print but little else. Skip unless users ask.
- **Declined — generic file-based trip *import*.** Loading a whole trip from an
  exported file means owning a versioned trip-file format, malformed-input
  handling, schema migration, and RLS-safe insertion with conflict-merge — high
  cost for a feature no one has requested. The real jobs are already covered:
  bookings *in* via paste/email import, others *see it* via share links +
  invites. Revisit only if E1/E2 land and users explicitly want file round-trip.

---

**Note on cross-references:** owner-gated *launch* items (App Group +
provisioning for the widget extension, App Store Connect setup, human-designer
icon pass, real-device auth/airplane-mode drills, `APPLE_SIWA_PRIVATE_KEY`
secret, disable anonymous sign-ins before launch) are tracked in
[RELEASE_READINESS.md](RELEASE_READINESS.md), not duplicated here.
