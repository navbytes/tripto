# Tripto — Product Plan: releases 1.2 → 1.4

Drafted 2026-07-21 (post-1.1 launch), by the product-owner engagement.
Inputs: competitive scan + Apple-platform research (July 2026, sources in
`.claude/company/roadmap-post-1.1/handoffs/`), codebase recon, and the
build-ready flight-status design (`.claude/company/release-1.2-flightstatus/`).
[BUILD_PLAN.md](BUILD_PLAN.md) remains the v1 architecture source of truth;
[ROADMAP.md](ROADMAP.md) remains the execution tracker — this doc sets product
scope and order for the next releases and supersedes ROADMAP.md's Phase 4/5
*ordering* (not its engineering content).

## 0. Strategy in one paragraph

Three moves, in order. **Close the last table-stakes gap** — per-booking
attachments; every serious competitor has documents-on-bookings and Tripto
doesn't. **Double down on the structural differentiator** — private on-device
AI: extend the shipped paste-import pipeline to screenshots and PDFs, which no
competitor does at all, and which server-side competitors (TripIt, Wanderlog)
cannot copy without rearchitecting. **Then ship the category's proven #1
retention feature** — live flight status — free to users under a hard cost
cap, where TripIt Pro and Flighty both charge ~$48–49/yr. Collaboration
(suggest tray) and AI garnish (summaries, packing suggestions) follow once
those land.

## 1. Evidence snapshot (2026-07-21)

**Market** (full matrix in handoffs/competitors.md):

- Attachments on bookings: TripIt ✓ (limited free, more paid; mobile upload
  is a top complaint), Tripsy ✓ (per-booking Documents, premium-gated),
  Wanderlog ✓ (Pro-gated, clunky), Flighty ✗, **Tripto ✗ — the gap**.
- Flight status/delay alerts: the anchor feature of both paid leaders
  (TripIt Pro $49/yr, Flighty ~$49–60/yr) — highest willingness-to-pay
  signal in the category. Two tempering facts: Kayak Trips gives basic
  alerts **free**, and iOS 26 Wallet now does boarding-pass Live Activities +
  baggage tracking natively for major US carriers — Apple is absorbing
  "flight companion" value into the OS. Conclusion: surface reliable status
  inline (don't chase Flighty's predictive ML), keep cost near zero.
- Multi-stop/multi-city trips: a real table-stakes gap (Wanderlog's core
  strength); schema-deep for Tripto (trip legs) — see §4.
- On-device/private AI parsing: **Tripto only.** Wanderlog's inbox-scanning
  draws explicit privacy complaints. "Your bookings never leave your phone"
  is a positioning asset competitors structurally can't match quickly.
- Screenshot→booking import: **nobody does it.** Bookings increasingly
  arrive as screenshots (WhatsApp/Instagram-era confirmations).
- Group-trip structure (roles): Flighty is solo-only, TripIt paywalls Teams,
  Tripsy has edit-conflict complaints — Tripto's roles + suggest tray is a
  real wedge.

**Platform** (full notes in handoffs/apple-intelligence.md):

- iOS 27 (beta now, GA ~Sept 2026): Foundation Models v2 accepts **image
  input** on-device; `@Generable` guided generation works over image+text;
  larger context. Device floor unchanged (iPhone 15 Pro+; ~55–60% of active
  iPhones).
- iOS 26 `RecognizeDocumentsRequest` (Vision): structured document OCR —
  text, tables, detected dates/codes — on **any A12+ device, no Apple
  Intelligence requirement**. `VNRecognizeTextRequest` covers iOS 17–25.
  PDFKit extracts text-based PDFs everywhere.
- Personalized Siri shipped through iOS 26.4; App Intents entities are the
  integration surface. Visual Intelligence gains third-party handlers in
  iOS 27 (freebie once App Intents exist).

**Codebase readiness** (scout, 2026-07-21):

- Storage seams proven: `StorageBucketPaths` owner-scoped pattern +
  lowercase-uid RLS rule, `ImageProcessing.downsampledJPEG()` compression,
  two working buckets. **But `trip-covers` is public-read — attachments need
  a new private, trip-membership-scoped bucket.**
- Import pipeline seams ready: `PasteImportSheet` → `ImportExtraction` route
  (on-device FM iOS 26+AI / cloud `ingest-text` with consent) → review inbox.
- No attachment table, no PDF/Vision usage, no share-extension target today.
  `ShareSummary` is text-only (sanitizer sentinel tests exist).

## 2. Release 1.2 — "Every booking carries its paper"

Theme: attach anything to a booking; turn anything into a booking. One
coherent story for the listing: *add a booking from a screenshot, keep the
ticket with it, all without your data leaving the phone.*

### 2.1 Per-booking attachments (images + PDFs)

**User value:** the QR-coded ticket, seat map, or hotel voucher lives with
the booking it belongs to — no gate-side digging through Mail/Files. Closes
the Tripsy/TripIt gap; our version is free (TripIt gates it behind Pro) and
syncs to all trip members.

Scope:

- Attach from Photos, Files, or camera on any itinerary item (not just
  bookings — a museum-tickets PDF on an activity is equally valid).
  Thumbnail strip on `BookingDetailView`; QuickLook full-screen viewer.
- Formats: JPEG/PNG/HEIC (re-encoded via existing `ImageProcessing`, long
  edge ≈2400px / quality 0.85 — higher than covers so barcodes stay crisp)
  and PDF (stored verbatim). Caps: 10 files per item, 10 MB per file
  (friendly error above).
- Offline: attachments cache locally after first view; items inside the
  next-7-days window prefetch on trip open — the airport-basement case.
- Visible to all trip members (companion adds the hotel PDF, organizer sees
  it). Delete: uploader or organizer.

Hard constraints (set in engagement DECISIONS.md):

- **New private bucket** (`item-attachments`), trip-membership-scoped RLS on
  both the table and storage objects; authenticated/signed access only.
  NOT the public-read covers pattern — these files carry PII and codes.
- **Share link never exposes attachments** — extend the existing
  `ShareSummary` sentinel tests to pin this.
- Attachment metadata rides the existing per-trip sync; files lazy-load.

Build shape: backend repo — one migration (`item_attachments` table +
storage bucket/policies), S/M, db-engineer. App — model/DTO + sync pull,
upload/download service reusing `StorageBucketPaths`, detail-view UI +
QuickLook, M/L. Security-auditor gates the RLS + storage policies
(pre-registered: membership check on every path segment, no public URLs,
signed-URL TTL). Verify current Supabase storage/egress quotas at build
time; caps + local caching keep us inside the near-zero cost posture.

Acceptance sketch: attached boarding-pass QR scans from screen at the gate;
attachment added by companion appears for organizer; airplane-mode relaunch
shows cached attachments for this week's items; share-link page shows no
trace of attachments; anon/other-trip user denied at storage level (psql
check in backend PR).

### 2.2 Screenshot & PDF import ("scan to add")

**User value:** the booking that arrived as a WhatsApp screenshot or an
airline PDF becomes a structured itinerary item in two taps. No competitor
does screenshot→booking at all.

Availability lattice (progressive, never device-gated as a whole):

| Tier | Devices | Path |
|---|---|---|
| 1 | iOS 26+, any chip | `RecognizeDocumentsRequest` OCR → existing text pipeline (on-device FM if AI-capable — no consent; else cloud `ingest-text` with existing consent gate) |
| 2 | iOS 17–25 | `VNRecognizeTextRequest` OCR → same routing |
| 3 | iOS 27 + AI device (fast-follow, ~Sept GA) | image straight into `LanguageModelSession` with the existing `@Generable` schemas — skip OCR |

- Entry points: photo/file pickers in the existing import sheet (rename of
  `PasteImportSheet` surface). PDFs: PDFKit text first, page-render → OCR
  for scanned ones.
- **Close the loop with 2.1:** after extraction, offer "attach the original
  to the new item" — the screenshot/PDF becomes the item's first attachment.
- Extracted items land as `suggested` in the existing review inbox — wrong
  parses stay one dismiss away (same quality valve as email import).
- Process batches serially with progress UI (FM thermal/rate limits).
- Compliance check (S, do first): App Review's Nov-2025 update to 5.1.2(i)
  requires *named*, pre-transmission disclosure for third-party cloud LLMs —
  verify the existing consent copy names the provider before the cloud path
  gains screenshot inputs.

Effort: M (OCR tiers + plumbing + sheet UI; extraction/review pipeline
already exists). Tier 3 is a point-release enhancement — do not gate 1.2 on
iOS 27.

### 2.3 Listing refresh (owner, with 1.2 ship)

Lead with the wedge: screenshot import + "bookings never leave your phone"
(on-device path), attachments free-for-everyone. App Store privacy labels:
no change for on-device paths; attachments use existing Supabase disclosure.

Out of 1.2 (deliberate): share-extension target (1.3/1.4 — provisioning +
new target; in-app pickers prove demand first); auto-attaching the PDF from
forwarded *emails* (worker + edge-function work; 1.3 candidate once the
attachments substrate exists); document vault (passports/insurance — stays
parked per ROADMAP Phase 5, different security posture).

## 3. Release 1.3 — "Travel day, live" ⚠ needs one owner decision

The design is already build-ready in
`.claude/company/release-1.2-flightstatus/PLAN.md` (2026-07-17): AeroDataBox
provider, poll-on-open + shared `flight_status` cache table, Supabase edge
function with per-day budget, kill switch, staleness-not-blankness, no PII
upstream. Shelved 2026-07-17 pending traction data (nt 1XVYYQ).

**Cost answer to "only if free":** validation starts on the free tier
(600 units); steady-state is the $5–15/mo AeroDataBox plan with a durable
per-day budget cap and `FLIGHT_STATUS_ENABLED` kill switch — exhausted
budget serves stale data, never spends more. Competitors charge users
$48–49/yr for exactly this; we'd ship it free.

Design stance the market data confirms: TripIt's worst recent complaint is
*wrong gate data nearly causing a missed flight* — the plan's
honest-staleness posture ("as of 12:04", serve stale, never guess) is the
differentiator that matters more than data breadth.

Staging (per the existing plan, unchanged): S0 spikes (free) → schema →
edge function deployed **dark** → app chip/card UI → security-audit gate →
owner flips the switch. Then, riding the same release train:

- **APNs push infrastructure** (ROADMAP 3.3, prerequisite for alerts):
  device-tokens table, send-push helper, settings toggle. First consumer is
  EI-5 (notify members on suggested-item insert) — value even without
  flight alerts.
- **Alerts + Live Activity live feed** (flight-status slice 2) once APNs
  lands — AeroDataBox Flight Alert API webhook → push → `LiveActivityCoordinator`
  gets real data. May slip to 1.3.x; poll-on-open alone is already visible
  value.
- Universal links (ROADMAP 3.2) — small, rides along.

**Owner decision needed (the only one in this plan):** approve reopening the
2026-07-17 shelve + the ~$5/mo ceiling. Recommendation: **go** — build dark
during/after 1.2, flip on when ready; the "traction" condition can be read
against 1.2-era App Store Connect metrics before the switch flips, so the
recurring spend starts only when real users exist.

## 4. Release 1.4 — "Smarter, together" (sketch; re-scope after 1.2 data)

- **Suggest tray** (ROADMAP 4.2): viewer/companion "suggest a plan" → review
  inbox. Mostly one RLS migration + an affordance now that email import
  built the plumbing. Group-trip differentiation vs solo/paywalled rivals.
- **Trip summary / "catch me up"** (S): on-device FM text generation over
  the itinerary; iOS 26+AI devices, quietly absent elsewhere.
- **Packing suggestions** (S): FM prompt over itinerary + destination +
  dates; suggestions-only UI, user confirms.
- **Deeper App Intents** (S/M, no AI gate): parameterized intents ("add
  sunscreen to packing", "what's my confirmation code for the Lisbon
  hotel?") on every device; iOS 27 Entity Schemas donate trips/bookings
  into Spotlight's semantic index — system-level NL answers without an
  in-app NL feature. (SiriKit is deprecated; App Intents is the only path.
  Note: full AI-Siri is EU-delayed under DMA.)
- **iOS 27 image-native extraction** (Tier 3 of §2.2) and **share-extension
  target** ("share to Tripto" from Photos/Files/Mail) — the import funnel's
  second act. Cheap adjacent trick worth a spike: iOS 26 Visual Intelligence
  already turns screenshots into Calendar events — observing
  `EKEventStoreChanged` and offering "import this booking?" rides Apple's
  own funnel (title/date/location only). The `TranslationSession` framework
  (universal, no AI gate) can pre-translate foreign-language confirmations
  before extraction.
- **Multi-stop trips** (candidate, needs a product-analyst spec first):
  ranked table-stakes by the competitive scan, but schema-deep — trip legs
  touch the data model, tz handling, and most screens. Spec it against
  1.2-era demand signals before committing; don't back into it.

## 5. Explicitly not doing (and why)

- **Natural-language search over trips** — lowest value/effort of the AI
  options (research verdict); Spotlight + in-app search already cover it.
- **Expenses** — one competitor has it, complaint volume low, big build
  (new tables/RLS/UI). Stays demand-gated in Phase 5.
- **Maps tab** — planner positioning, not organizer; Tripsy/Wanderlog own
  it; MapKit makes it cheap *later* if demand shows.
- **Document vault** (passports/visas) — separate encryption/security
  posture decision; don't blur it into 2.1. Parked.
- **Flight-status data on the public share link** — deliberate 1.3 scope
  cut (third-party ToS exposure), per the flight-status plan.
- **E4 PDF itinerary** — still parked, but with a named trigger now:
  Tripsy paywalls sharing and removed PDF export to user anger; if share-link
  feedback asks for print/offline, a free PDF render of the sanitized share
  view is the cheap answer.
- Android/web, in-app booking, chat, AI trip generation, social — unchanged
  (BUILD_PLAN §2).

## 6. Measurement & gates

No analytics SDK gets added (privacy posture). Signals we already have:

- App Store Connect: downloads, retention, crash-free.
- Server-side organic (SQL, read-only): trips created/week, `email_imports`
  volume + status mix, and — post-1.2 — `item_attachments` rows/trip and
  text-vs-screenshot import mix (`source` field), which proxy adoption of
  the release themes.
- Gates: 1.3 switch-flip waits for 1.2-era traction per §3; 1.4 scope
  re-ranked against 1.2 adoption data (if screenshot import dominates,
  pull the share extension forward).

## 7. Dependencies & owner actions

| When | Action | Why |
|---|---|---|
| 1.2 build | (team) backend migration: `item_attachments` + private bucket + RLS — in `~/repos/backend/projects/tripto` | hard two-repo rule |
| 1.2 ship | 🔑 listing refresh (§2.3) | marketing the wedge |
| 1.3 go | 🔑 approve flight-status reopen + ~$5/mo ceiling (§3) | the one money call |
| 1.3 build | 🔑 APNs key (.p8) into Supabase secrets (ROADMAP 3.3) | push infra |
| 1.3 build | 🔑 AeroDataBox account + key at S0c smoke test | provider access |
