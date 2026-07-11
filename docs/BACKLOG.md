# Tripto — Backlog & Deferred Items

Gaps and deferred work identified across engagements, to pick up **after the
current server-side privacy phase**. Owner-gated launch steps live in
[RELEASE_READINESS.md](RELEASE_READINESS.md) — this file is the working
backlog of things we chose to defer, not re-list.

Last updated: 2026-07-12 (§A status updates: email-import worker built + audited, consent gate shipped, crons live; §E1 shipped).

---

## A. Email import lifecycle (do as one cluster, before email goes live)

The inbound email-import feature (EI) is partially built and **not live** (MX
not switched on). These belong together and should ship as a unit:

- **A1 — Build the EI-3 Cloudflare Email Worker.** ✅ **SHIPPED (PR #19).** Inbound MIME parsing +
  forwarding to the `ingest-email` edge function. Code complete, tested, security-audited (20s timeout + gitignore hardening landed).
- **A2 — Enable the email-import pipeline** (MX / routing to
  `plans.tripto.navbytes.io`). 🔑 **Owner action.** Prerequisites before go-live: ✅ retention crons live (PR #6 in backend, verified 2026-07-12); ⏳ worker deployed + `EMAIL_INGEST_SHARED_SECRET` set on both ingest-email (Supabase) and email Worker (wrangler); ⏳ DNS MX scoped to `plans.tripto.navbytes.io` only, catch-all rule → Worker.
- **A3 — [WAS F2, privacy] Automated purge of raw import emails.** ✅ **LIVE (backend PR #6, deployed 2026-07-12).** `pg_cron` jobs active: `raw_text`/`raw_html`/`parsed_json` nulled >6 days (≤7d guarantee), `text_import_events` pruned >1d, `accounts.deleted_at` scrub includes `parsed_json`. Verified active in production cron.job. Account deletion (PR #7, deployed) now includes parsed_json sanitation.
- **A4 — Privacy-audit the EI-3 worker once built.** ✅ **AUDITED (2026-07-12).** Worker MIME parsing, token/From/Subject/body extraction, shared-secret auth verified; no extraneous headers or metadata passed to edge function. No further security concerns identified.
- **A5 — Explicit AI-processing consent for email import.** ✅ **SHIPPED (PR #20).** Apple Guideline 5.1.2(i) compliance: `ImportAddressCard` gates address reveal behind a consent dialog; users must tap "Continue" on the confirmation dialog (disclosing third-party AI, 7-day raw retention, code privacy) before the address is shown. Shared by `ItineraryTabView` and `ShareTripView`; one dialog, consistent copy. "Not now" leaves card in `.needsConsent` state, re-tappable.

## B. Cost / abuse hardening

- **B1 — [F5] Rate-limit `ingest-text`.** ✅ **SHIPPED (backend PR #5).** `ingest-text` edge function now rate-limited 20/hr/user, matching `ingest-email`. Cost + abuse surface hardened before meaningful scale.

## C. Ops & security hygiene (post-launch)

- **C1 — Secrets rotation procedure.** ✅ **DOCUMENTED (backend RUNBOOK.md, PR #8).** `EMAIL_INGEST_SHARED_SECRET` and Cloudflare gateway / LLM keys emergency revocation procedures captured. Rotation schedules and guardrails ready for ops handoff.
- **C2 — Supabase auth advisors** (low relevance while Sign-in-with-Apple is
  the only method — no passwords, Apple provides 2FA): leaked-password
  protection and additional MFA options are OFF. Revisit only if password or
  other auth methods are ever added.
- **C3 — Confirm the production LLM model actually works via Cloudflare AI
  Gateway.** ✅ **VERIFIED (2026-07-12).** Live smoke test passed: anon → trip → ingest-text 200 (1 flight + 3 packing items via CF AI Gateway/gpt-4.1-mini), delete-account 204 (zero residue). Production LLM routing confirmed working end-to-end.
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

- **E1 — Whole-trip Calendar export.** ✅ **SHIPPED (PR #21).** Add entire itinerary to Calendar + .ics export via EKEvent batch. Client-only, zero-opex. Highest value-per-effort. Also fixed calendar-permission crash that occurred on devices without prior calendar access grant.
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
