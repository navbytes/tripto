# Tripto — Backlog & Deferred Items

Gaps and deferred work identified across engagements, to pick up **after the
current server-side privacy phase**. Owner-gated launch steps live in
[RELEASE_READINESS.md](RELEASE_READINESS.md) — this file is the working
backlog of things we chose to defer, not re-list.

Last updated: 2026-07-11 (after the server-side data-handling privacy audit).

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

## D. Larger deferred product work (from BUILD_PLAN v1.5/v2)

Not started, intentionally out of v1 — listed so they aren't lost:
- Email-forward parser for the top providers (the "magic" moat, BUILD_PLAN §2).
- Real-time flight status (one aggregator API).
- Suggest-without-editing tray for companions.
- Expense tracking/splitting, document vault, maps tab, discovery.

---

**Note on cross-references:** owner-gated *launch* items (App Group +
provisioning for the widget extension, App Store Connect setup, human-designer
icon pass, real-device auth/airplane-mode drills, `APPLE_SIWA_PRIVATE_KEY`
secret, disable anonymous sign-ins before launch) are tracked in
[RELEASE_READINESS.md](RELEASE_READINESS.md), not duplicated here.
