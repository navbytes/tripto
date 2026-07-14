# Tripto — Implementation Roadmap

Drafted 2026-07-13 from [BACKLOG.md](BACKLOG.md), [EMAIL_IMPORT_PLAN.md](EMAIL_IMPORT_PLAN.md),
[RELEASE_READINESS.md](RELEASE_READINESS.md), and [BUILD_PLAN.md](BUILD_PLAN.md) §2.
This is the execution plan for everything open in the backlog, sequenced and
sized. BUILD_PLAN.md remains the product source of truth; this doc orders the
work and records what each item needs to ship.

**Position today (updated 2026-07-14):** v1 submitted to App Review
2026-07-12 (Build 6, Waiting for Review). Backend cutover complete (anon
sign-ins off, anon data purged, `/privacy` live). 610 unit + 6 UI tests
green. **Email import is live** (since 2026-07-11 — the "not live" premise
this doc was drafted under was stale; see §0 and Phase 1). Archive
import/export (Phase 2) is built and verified on `main`'s working tree and
ships in the next build.

Status keys: ✅ done · 🔄 in progress · ⏳ queued (team can do it) ·
🔑 owner-only · 🅿 parked (demand-gated).

---

## 0. Corrections to BACKLOG.md found while drafting (doc drift)

Verified against the code on `main`, 2026-07-13:

- **E2 "Duplicate trip" is SHIPPED**, not pending — `Models/TripDuplication.swift`
  + Home/TripForm UI + `TriptoTests/TripDuplicationTests.swift` are on `main`,
  and RELEASE_READINESS confirms Build 6 carries the duplicate-trip work.
  BACKLOG §E2 should be marked ✅ (PR #21 era).
- **§E's "Declined — generic file-based trip import" is superseded** by owner
  direction (2026-07-13): migration import for users coming from other apps is
  now wanted. The revisit trigger §E named ("E1/E2 land and users explicitly
  want file round-trip") has fired — E1 and E2 are shipped, and the owner is
  the first migrating user (25-trip archive). Phase 2 below is the revised,
  much cheaper plan; §E should point here.
- **EI-2 is merged to `main`** (suggested-items review flow ships in Build 6);
  EMAIL_IMPORT_PLAN's "on branch email-import-app (PR #4)" wording is stale.
- **EI-4 is partially done**: the 7-day retention cron shipped with backend
  PR #6. What remains of EI-4 is reprocessing, rate-limit tests, and
  unverified-sender UX (→ item 1.4).

A docs-sync task to fold these into BACKLOG.md is included in Phase 2 (2.5).

---

## Phase 0 — Release window (now; owner-gated, no engineering)

Everything here is in RELEASE_READINESS.md; listed only for sequencing. The
team keeps `main` stable and treats review feedback as the only interrupt.

| # | Item | Who | Notes |
|---|------|-----|-------|
| 0.1 | Manually release Build 6 once review passes | 🔑 | The release button in App Store Connect. |
| 0.2 | Airplane-mode round-trip on a real device | 🔑 | Recommended, not a blocker. Edit offline → reconnect → reconciles, shows "edited by X". |
| 0.3 | TestFlight upgrade-over-Build-4 check | 🔑 | Confirms the SwiftData lightweight migration (`sourceRaw` on `ItineraryItem`) on a dirty install. Recovery: delete + reinstall (backend re-syncs). |

**Exit criteria:** app live on the App Store; no migration regressions reported.

---

## Phase 1 — Email import go-live (BACKLOG §A2 + EI-4 remainder)

**Why first:** the entire pipeline is built, audited, and idle — worker (PR #19),
edge function, consent UI (PR #20), retention crons (backend PR #6), review
inbox (EI-2). This is BUILD_PLAN's v1.5 "magic" moat, and it is one console
session away from live. The LLM-extraction design already covers arbitrary
providers, so BUILD_PLAN's original "parser for top 10–15 airlines" v1.5 item
is delivered by this go-live plus quality iteration — no separate build.

### 1.1 ✅ Go-live runbook + verification script — devops · S (~half day)

Consolidate EMAIL_IMPORT_PLAN's go-live gate into one runnable checklist:
pre-flight (secrets present on both sides, worker config sane), a curl-level
smoke of `ingest-email` with the shared secret, and post-MX checks (dig MX on
`plans.tripto.navbytes.io`, apex MX untouched, catch-all → worker). Output:
`web/email-worker/RUNBOOK.md` + `scripts/check-golive.sh` — both landed, verified 2026-07-14.

### 1.2 ✅ Owner console batch — ~30 min, one sitting

1. ✅ `EMAIL_INGEST_SHARED_SECRET` set on **both** `ingest-email` (Supabase) and
   the email worker (`wrangler secret put`) — must match exactly.
2. ✅ DNS: MX **scoped to `plans.tripto.navbytes.io` only** (never the apex —
   iCloud+ mail lives there), catch-all route → email worker.
3. ✅ Unified Billing credits loaded (Cloudflare AI Gateway → Credits Available).
4. ✅ `wrangler deploy` from `web/email-worker` (completed 2026-07-11).

### 1.3 ✅ Post-live end-to-end verification — qa-verifier · S

Forward a real airline confirmation to a trip's `t-<token>@…` address →
suggested item appears in the review inbox → confirm flow works → AI Gateway
log shows the `anthropic/claude-haiku-4-5` call → `email_imports` row lands
and its raw fields purge on schedule. ✅ End-to-end verification was done
2026-07-11 (HANDOVER_2026-07-10.md §2); 2026-07-14 added a read-only infra
re-check (`scripts/check-golive.sh`, all gates ✅). A fresh forward-an-email
spot check by the owner remains a recommended nicety, not a gate. BACKLOG
§A2 marked ✅.

### 1.4 ⏳ EI-4 remainder (hardening) — backend-coder + coder + tester · M (~2 days)

- **Reprocess path**: rerun `low_confidence`/`rejected`/`failed`
  `email_imports` rows after a prompt fix, within the 7-day raw-retention
  window (backend RPC or admin script — decide smallest that works).
- **Rate-limit tests**: prove 20/hr/user on `ingest-email` + `ingest-text`
  (backend repo test suite).
- **Unverified-sender UX**: badge a suggested item whose `From` didn't match a
  trip member (data already lands; app-side chip + one line in the review
  sheet). Small RLS-safe read, no schema change expected.

### 1.5 🔑 Listing refresh once stable — owner · S

Promotional text / description gain the "forward your confirmation email"
line only after 1.3 passes. Privacy disclosure already covers the LLM path.

**Exit criteria:** a stranger can forward a booking email and review the
suggested item in-app; failure modes are observable (`email_imports.status`
distribution) and reprocessable.

**Risks:** long-tail provider emails parse poorly → mitigated by balanced
confidence gating + review inbox (wrong suggestion = one dismiss tap), and by
1.4's reprocess loop for prompt iteration. Model/provider swap is a secret
change (`LLM_MODEL`), not code.

---

## Phase 2 — Migration import & data portability (BACKLOG §E revised)

**Why now:** owner-observed demand (the §E revisit trigger). One versioned
archive format serves **import (migration), E3 export (privacy/portability),
and deterministic test seeding** — three backlog concerns, one schema. The §E
cost objections have shrunk: item mapping/validation exists
(`ImportExtraction.swift`), the bulk RLS-safe write pattern exists
(`DemoSeeder.swift`), non-app travellers are `trip_profiles` by design, and
IATA→zone resolution exists (`AirportTimeZones.swift`). **No backend changes**
— all inserts are ordinary client writes by the signed-in user through the
outbox; imported items land `status='confirmed'`, `source='manual'` (no new
enum value, no migration).

### 2.1 ✅ "Tripto Archive v1" format spec — architect + docs-writer · S

`docs/IMPORT_FORMAT.md`: versioned envelope
(`{"format":"tripto-archive","version":1,"trips":[…]}`); trip fields (title,
destination, country, ISO dates, travellers as display names, optional
status); items in the `RawExtractedItem` vocabulary (`flightNo`, `fromIATA`,
`arrivalTz`, `room`, …) with naive local datetimes + IATA codes allowed.
Includes an **LLM conversion appendix**: a paste-ready prompt so anyone can
turn a TripIt/Flighty/email-archive export into this format with any AI —
that's the answer to "N source apps × M formats": conversion is delegated to
AI outside the app; the app owns only deterministic materialization. **Frozen 2026-07-13.**

### 2.2 ✅ Archive importer in-app — coder + tester + reviewer · M/L (~2 days)

- ✅ Settings → "Import trips" → `fileImporter` (.json). Deterministic decode —
  **no AI, therefore no 5.1.2(i) consent dialog**.
- ✅ Mapping: flight tz from origin IATA (extended `AirportTimeZones`),
  `arrivalTz` from destination IATA, fallback to trip-destination zone; date-only times get
  category defaults (hotel 15:00/11:00, etc.); travellers →
  `trip_profiles`; trips with no dates skipped + reported; cancelled trips
  skipped by default.
- ✅ **Idempotence:** trip/item UUIDs = UUIDv5 of the archive's stable ids —
  re-import converges instead of duplicating.
- ✅ Writes: phased pattern (trip → flush → profiles → flush →
  items → flush) ensuring server trigger seats the organizer before dependent
  rows.
- ✅ Import report sheet: displays summary + per-trip skips with reasons.
  Malformed file fails atomically with a friendly error.
- ✅ Tests: pure-mapper unit tests (tz resolution, skips, idempotence) + fixture.
  Built + review-verified 2026-07-14 on `main`'s working tree — ships in the
  **next** build (Build 6, in review, predates this feature).

### 2.3 ✅ E3 "Download my data" export — coder · S/M (~1 day)

✅ Settings → "Export my trips": emit the **same** Archive v1 JSON of owned
trips via `ShareLink`. Round-trip test: export → import → zero new rows
(UUIDv5 idempotence verified). Scope strictly to
requester-owned rows (RLS enforced server-side; exporter reads the
local mirror). No sanitization — it's the owner's own data. Built + verified
2026-07-14 (unit suite 509→610); ships in the next build.

### 2.4 ⏳ ~~E2 Duplicate trip~~ — ✅ already shipped (see §0); no work.

### 2.5 ✅ Docs sync — docs-writer · S

✅ BACKLOG §E rewritten to point here (supersession + trigger recorded), §A2/E2/E3
statuses corrected, CHANGELOG entries added, TESTING.md gains "seed via archive
import" as the sanctioned test-data path. Completed 2026-07-14.

**Exit criteria:** owner's real 25-trip archive imports on a signed device,
syncs to Supabase, renders correctly in upcoming/past (tz-correct per
ACCEPTANCE.md cases); export→import round-trips clean.

**Risks:** naive local datetimes with unknown airports → resolved zone falls
back to trip destination; every imported field remains editable in-app, so
worst case is a visible, correctable time — never a silent UTC shift.

---

## Phase 3 — Platform & test hygiene

Independent small items; slot around Phases 1–2 as review/QA capacity allows.

### 3.1 ⏳ C4 — Hermetic UI tests — coder + tester · M (~1–2 days)

**Promoted from "decided against":** the launch cutover disabled anonymous
sign-ins in production, so today every `TriptoUITests` run requires toggling a
**production auth setting** on and off (TESTING.md prerequisite). That was
tolerable pre-launch; it is not a sane post-launch workflow, and it's one
forgotten toggle away from re-enabling anon sign-ups in prod. Fix per C4's own
sketch: `-uitestAutoSignIn` injects a fake authenticated session behind
`#if DEBUG` (AuthManager seam) instead of calling real
`signInAnonymously()`. UI tests stop touching the network; the TESTING.md
prerequisite and the RELEASE_READINESS warning both get deleted.
Fallback if supabase-swift session injection fights back: a `debugger`-led
spike before committing to the seam design.

### 3.2 ⏳/🔑 Universal links — S (mostly owner console)

Per EMAIL_IMPORT_PLAN Feature 2: 🔑 enable **Associated Domains** on App ID
`io.navbytes.tripto` → ⏳ add the `applinks:tripto.navbytes.io` entitlement to
`project.yml` + `xcodegen` → 🔑 verify a `/join/<token>` link opens the app on
a signed device. Include the two noted cleanups (share-worker README paths,
stale `project.yml` TODO). AASA is already live and correct. Additive polish —
custom-scheme invites already work.

### 3.3 ⏳/🔑 Push notification infrastructure (EI-5 + prerequisite for 4.1) — backend-coder + coder + security-auditor · M/L (~2–3 days)

🔑 APNs key (.p8) as a Supabase secret. Backend: `device_tokens` table
(deny-all RLS, edge-only, mirroring `apple_refresh_tokens`), a `send-push`
edge helper. App: registration + token upload on sign-in, settings toggle.
First consumer: notify trip members on suggested-item insert (EI-5, v1.1
promise). Security-auditor reviews token handling + the edge function.
Do this when v1.1 is scheduled — or pull it forward as 4.1's prerequisite.

---

## Phase 4 — v1.5 product features (BUILD_PLAN §2, demand-informed order)

Start after Phase 1–2 land and initial store signal exists. Each begins with a
product-analyst spec against BUILD_PLAN's constraints.

### 4.1 🅿→⏳ D2 — Real-time flight status — L/XL (~1–2 weeks, staged)

BUILD_PLAN commits to **one** aggregator. Stage the ship:

1. **Research** (researcher · S): pick the aggregator — evaluate AeroDataBox /
   FlightAware AeroAPI / equivalents on per-call price at our volume, delay +
   gate + terminal fields, poll vs webhook, and free-tier viability. ADR in
   `docs/`.
2. **Backend proxy** (backend-coder · M): edge function `flight-status`
   holding the API key (never in the app), keyed by flight number + date;
   response cached in a table with a short TTL so N family members don't fan
   out N upstream calls. Rate-limited like the ingest functions.
3. **App, pull-first** (coder · M): status chip on the flight card +
   BookingDetail (delay/gate), fetch-on-open + pull-to-refresh. Live Activity
   already exists (`LiveActivityCoordinator`) — feed it real status.
4. **Proactive alerts** (M, requires 3.3): a cron polls upcoming flights
   (next 48h) and pushes on status change.

Cost posture: cache + poll-only-imminent-flights keeps this near-zero at
current scale, per BUILD_PLAN §3's cost stance.

### 4.2 🅿→⏳ D3 — Companion/viewer "suggest" tray — M (~2 days)

The suggested-items infrastructure (EI-2: status, review banner, inbox,
confirm/dismiss) is live — this feature is now mostly **one RLS policy + one
affordance**: allow the viewer role INSERT of `status='suggested'` items
(migration in the backend repo), and an in-app "Suggest a plan" entry for
viewers/companions routing into the existing review inbox. Exactly the
BUILD_PLAN v1.5 "propose-without-editing-master" item, at a fraction of its
original cost because email import paid for the plumbing.

### 4.3 🅿 Import Stage 2 — ICS ingestion / in-app AI bulk conversion

Demand-gated extensions of Phase 2: accept `.ics` (map events through the
existing extraction/review pipeline as `suggested` items) and/or in-app AI
conversion of arbitrary pasted exports into Archive v1 (reuses `ingest-text` +
the existing consent gate). Build only on observed migration demand
(support asks, reviews). Until then the LLM-conversion appendix (2.1) covers it.

---

## Phase 5 — v2 parking lot (no work scheduled; demand-entry only)

Per BUILD_PLAN §2 "Depth", each enters via a product-analyst spec + observed
demand; none is started on spec alone:

- **Expense tracking/splitting** — family default *tracking*, friends default
  *split* (§5.5). Largest v2 item; new tables + RLS + UI surface.
- **Document vault** — passports/visas/insurance; needs a storage + encryption
  posture decision (Supabase Storage vs on-device only) and a security audit.
- **Maps tab** — MapKit routing between stops; client-only, medium.
- **Discovery/recommendations** — furthest out; explicitly not before the
  organizer + moat retain.
- **E4 PDF itinerary** — likely permanently redundant to the share link; keep
  parked unless users ask.
- **C2 auth advisors** — conditional: only if a non-Apple auth method is ever
  added (leaked-password protection, MFA options).

Explicitly out of scope, unchanged (BUILD_PLAN §2): in-app booking/payments,
chat, AI trip generation, social feed.

---

## Cross-cutting rules (apply to every phase)

- **Two-repo boundary:** schema/RLS/edge-function changes happen only in
  `~/repos/backend/projects/tripto` migrations; never DDL from this repo; the
  service-role key never appears here. Client assumes RLS deny-by-default.
- **Quality bar on any new UI** (CLAUDE.md): full Dynamic Type incl.
  accessibility sizes, VoiceOver labels, Reduce Motion, AA contrast, 44pt
  targets, motion/haptics via `Design/Motion.swift`, tokens only (no raw hex).
- **Build discipline:** `project.yml` is truth → `scripts/bootstrap.sh` after
  file adds; own `-derivedDataPath` per CLI build; SwiftLint `--strict` gates
  CI; every push runs Tripto-CI unit tests in Xcode Cloud.
- **Definition of done:** built + unit-tested + reviewed; security-auditor on
  anything touching auth/input/secrets/network; qa-verifier evidence for
  user-visible flows; docs (CHANGELOG/BACKLOG/TESTING) updated in the same PR.
- **Auth-write verification needs a signed build** (Keychain session) — plan
  device time for any sync-writing feature (Phases 2, 4).

---

## Sequencing at a glance

| Phase | Item | Size | Blocked by | Status |
|-------|------|------|------------|--------|
| 0 | Release Build 6 + device checks | — | App Review | 🔑 waiting |
| 1 | 1.1 Go-live runbook/script | S | — | ✅ |
| 1 | 1.2 Console batch (secrets, MX, credits, deploy) | S | — | ✅ 2026-07-11 |
| 1 | 1.3 E2E verification | S | 1.2 | ✅ 2026-07-11 |
| 1 | 1.4 EI-4 remainder (reprocess, RL tests, sender UX) | M | 1.3 | ⏳ |
| 2 | 2.1 Archive v1 format spec | S | — | ✅ 2026-07-13 |
| 2 | 2.2 Archive importer | M/L | 2.1 | ✅ 2026-07-14 |
| 2 | 2.3 E3 export (same format) | S/M | 2.1 | ✅ 2026-07-14 |
| 2 | 2.5 Docs sync (incl. §0 corrections) | S | 2.2 | ✅ 2026-07-14 |
| 3 | 3.1 C4 hermetic UI tests | M | — | ⏳ ready |
| 3 | 3.2 Universal links | S | 🔑 capability | ⏳/🔑 |
| 3 | 3.3 Push infra + EI-5 | M/L | 🔑 APNs key | 🅿 v1.1 |
| 4 | 4.1 Flight status (staged 1→4) | L/XL | spec; stage 4 needs 3.3 | 🅿 |
| 4 | 4.2 Suggest tray | M | backend RLS migration | 🅿 |
| 4 | 4.3 ICS / AI bulk import | M | demand | 🅿 |
| 5 | Expenses / vault / maps / discovery / E4 / C2 | XL… | demand | 🅿 |

**Team-executable immediately, no owner input:** 1.1, 2.1 → 2.2 → 2.3 → 2.5,
and 3.1. **The single owner batch that unlocks the most value:** 1.2's console
sitting (email import goes live). Phases 1 and 2 are independent tracks and
can run in parallel.

---

## Consolidated owner-action list (🔑, batched)

1. **Now / on approval:** release Build 6; airplane-mode + TestFlight-upgrade
   device checks (0.1–0.3).
2. **One console sitting (unlocks Phase 1):** shared secret both sides, MX +
   catch-all on `plans.tripto.navbytes.io` (never apex), Unified Billing
   credits, worker deploy (1.2). Then the listing refresh later (1.5).
3. **When convenient (unlocks 3.2):** enable Associated Domains on the App ID;
   afterwards verify a `/join` link on device.
4. **When v1.1 is scheduled (unlocks 3.3 → 4.1 stage 4):** APNs key.
