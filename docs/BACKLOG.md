# Tripto — Backlog & Deferred Items

Gaps and deferred work identified across engagements, to pick up **after the
current server-side privacy phase**. Owner-gated launch steps live in
[RELEASE_READINESS.md](RELEASE_READINESS.md) — this file is the working
backlog of things we chose to defer, not re-list.

Last updated: 2026-07-15 (§F added — UX redesign Phase 6's fenced items). Prior: 2026-07-14 (§A2 ✅ email-import pipeline go-live complete; §E2/E3 archived, §E superseded by Phase 2).

---

## A. Email import lifecycle (do as one cluster, before email goes live)

The inbound email-import feature (EI) is partially built and **not live** (MX
not switched on). These belong together and should ship as a unit:

- **A1 — Build the EI-3 Cloudflare Email Worker.** ✅ **SHIPPED (PR #19).** Inbound MIME parsing +
  forwarding to the `ingest-email` edge function. Code complete, tested, security-audited (20s timeout + gitignore hardening landed).
- **A2 — Enable the email-import pipeline** (MX / routing to
  `plans.tripto.navbytes.io`). ✅ **LIVE since 2026-07-11.** MX + catch-all active on `plans.tripto.navbytes.io`, worker deployed, shared secret set on both sides, Cloudflare credits loaded. Go-live verified end-to-end per Handover documentation (2026-07-10) and re-verified read-only 2026-07-14 (web/email-worker/RUNBOOK.md + scripts/check-golive.sh). Remaining §A work: **reprocess path** ✅ **BUILT & LIVE (backend 2026-07-14; app DTO tests in repo)**; **unverified-sender UX** ✅ **BUILT & SHIPPED (badge + operator reprocess; app tests in repo)**. Only H1 (atomic rate-limit) remains, in flight as release-1.1 WP1.
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
  coupling).** ✅ **SHIPPED 2026-07-14.** `-uitestAutoSignIn` now injects a
  fixed fake session directly in `AuthManager.init` (`#if DEBUG`) instead of
  calling the real `signInAnonymously()` (deleted repo-wide); `TriptoUITests`
  make zero live network calls and pass with backend anonymous sign-ins OFF.
  See `docs/TESTING.md`.

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
- **E2 — "Duplicate trip" (retention hook).** ✅ **SHIPPED (Build 6).** Clone an existing trip as a
  template (re-run an annual trip): copy items with dates rebased, drop
  confirmation codes/bookings, keep the owner as sole member. Shipped in `Models/TripDuplication.swift` + UI in Home/TripForm + `TriptoTests/TripDuplicationTests.swift` (PR #21 era).
  - **Follow-up (qa D1, fixed):** duplicating a trip never opened this session cloned an itemless copy — `pullHome` doesn't load items, so the source's rows weren't local. Now pulls the source first (`HomeDuplication.cloneContent` + `HomeDuplicationTests`). **Known gap:** doing this *offline* still yields an empty copy (`pullTrip` no-ops with no network, nothing local to clone). Low priority — surface a "connect to copy this trip's plans" note if it ever bites.
- **E3 — "Download my data" export (privacy / compliance).** ✅ **SHIPPED 2026-07-14.** Settings → "Export trips" writes Tripto Archive v1 JSON (spec: `docs/IMPORT_FORMAT.md`), scoped to the owner's trips only (RLS-enforced server-side). Works bidirectionally with E3 import below — round-trip re-import is a no-op via UUIDv5 idempotence. No sanitization — it's the owner's own data. Exported scope constraints noted in IMPORT_FORMAT.md §7.
- **E4 — PDF / printable itinerary (low priority, likely redundant).** The
  public share link (§5.2) already gives a no-app, read-only view for
  grandparents; a PDF adds offline-print but little else. Skip unless users ask.
- **~~Declined — generic file-based trip *import*.~~** ✅ **SUPERSEDED 2026-07-13.**
  ~~Loading a whole trip from an exported file means owning a versioned trip-file format, malformed-input handling, schema migration, and RLS-safe insertion with conflict-merge — high cost for a feature no one has requested.~~ Owner-observed migration demand (25-trip archive) triggered the revisit. Replaced by deterministic Archive v1 import: Settings → "Import trips" (JSON, `docs/IMPORT_FORMAT.md`), on-device, no AI/consent, idempotent re-import, tz-resolving with UUIDv5 deduplication. Design and implementation in Phase 2 of `ROADMAP.md`; the E1/E2 revisit trigger has fired.

## F. UX redesign — fenced items (Phase 6, docs/UX_REDESIGN_ROADMAP.md)

The redesign program's own fence list ("Fenced out of this program," top of
`UX_REDESIGN_ROADMAP.md`) pushed these out of scope; captured here per that
doc's own instruction ("filed in BACKLOG.md, not silently dropped"). Not
ranked — pick up by demand, same as section E.

- **F1 — `ItemStatus.cancelled` + "Import anyway."** The archive-import
  result sheet (P6.1, `ImportResultSheet.swift`) can only offer a recourse a
  user can actually act on; a cancelled-trip skip has none today because the
  schema has nowhere to import a cancelled trip *into* —
  `Models/Enums.swift`'s `ItemStatus` is `suggested`/`confirmed` only, and
  trips carry no status column at all. Needs a backend enum/schema change
  before "Import anyway" (mockup note 4) is buildable.
- **F2 — Undated trips.** Same shape of gap: an archive trip with no start
  date is skipped (`TripSkipReason.noStartDate`) with no "Add dates"
  recourse (mockup note 4), because `trips.start_date`/`end_date` are `not
  null` — there's nowhere to persist a trip while its dates are unknown.
  Needs a schema change (nullable dates, or a distinct "draft" trip shape)
  before this is buildable client-side.
- **F3 — Cross-trip traveller identity.** P6.3 dedupes `trip_profiles` rows
  *within one trip* only (normalized display name — `ProfileDedupe.swift`).
  Recognizing "this is the same Grandma across 20 different trips" needs a
  person entity that outlives any single trip's `trip_profiles` row — a real
  backend concept this schema doesn't have today, not a client-side
  heuristic. The mockup's own reference (import-result note 3, "43
  travellers... share a name or email across trips") is this exact case;
  not built — P6.1's result sheet has no cross-trip travellers-smell banner
  at all (P6.3 covers the within-trip case, surfaced per-trip on Share).
- **F4 — Archive export item-scope verification.** Flagged, not fixed: like
  P6.2's trip-merge (which explicitly pulls both trips before moving
  anything — nt lesson YEFXVP), `SettingsView.exportArchive()` fetches
  straight from the local SwiftData mirror, which is **trip-scoped** —
  itinerary items/packing only enter it via `pullTrip` (opening the trip),
  never via `pullHome` (Home's own list pull). A trip never opened this
  session may export with zero items even though the server has them,
  understating the archive for exactly the trips a "back up everything"
  user is least likely to have opened recently. Needs verification (does
  export need to pull every trip first?) and, if confirmed, a fix — out of
  this phase's scope.
- **F5 — Multi-stop trips.** Out of the redesign program per BUILD_PLAN §2
  (v1 scope); unchanged by Phase 6.
- **F6 — Home-timezone setting.** A user-set "home" zone (for a "was I home
  or away" framing) — out of the redesign program; unchanged by Phase 6.

## G. Release 1.2 deferrals (2026-07-21)

Items deliberately deferred from the 1.2 scope (attachments & scan-to-add) per
PRODUCT_PLAN §2.3; pick up on demand or as part of adjacent releases.

- **G1 — Camera capture in the attach flow.** Deliberate cut. PRODUCT_PLAN §2.1
  listed it; needs `NSCameraUsageDescription` + App Review surface (inline
  camera picker vs. forwarding to system Camera app is a guidance question).
  In-app photo pickers already work (Photos/Files); camera demand can be
  validated after v1.2 ships. Pick up on demand.
- **G2 — Server-side per-item attachment COUNT cap.** Client-only 10/item today
  (friendly error above cap). DB advisory-lock trigger precedent exists if
  abuse surfaces (reviewer M1 accepted; no enforcement implemented). Leave
  until production abuse data warrants it.
- **G3 — Live smoke of ingest-text `createdItemIds`.** Blocked by prod anon-
  sign-in setting: Supabase Auth "anonymous sign-ins" is OFF on the project
  (prerequisite for `scripts/smoke-ingest.sh`). Self-verifies via first real
  cloud scan-import once users exercise it; owner can alternatively toggle
  `anonymous_provider_enabled` in Dashboard Auth + run the backend repo's
  `scripts/smoke-ingest.sh` if immediate verification is needed. Backend PR
  #18 is typed and deployed; no risk to deferring live check.
- **G4 — iOS 27 image-native extraction + share extension.** Tier 3 scan path
  (`LanguageModelSession` direct image input; iOS 27 GA ~Sept 2026, device
  floor 55–60% of active iPhones) and share-extension target remain 1.4
  candidates per PRODUCT_PLAN §4 (provisioning + new target; in-app pickers
  prove demand first).

---

**Note on cross-references:** owner-gated *launch* items (App Group +
provisioning for the widget extension, App Store Connect setup, human-designer
icon pass, real-device auth/airplane-mode drills, `APPLE_SIWA_PRIVATE_KEY`
secret, disable anonymous sign-ins before launch) are tracked in
[RELEASE_READINESS.md](RELEASE_READINESS.md), not duplicated here.
