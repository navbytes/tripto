# Tripto — Growth & Adoption Roadmap

**Living tracker for the current adoption push.** This is the *strategic /
growth* layer; the *engineering execution* phases live in
[ROADMAP.md](ROADMAP.md), release scope in [PRODUCT_PLAN.md](PRODUCT_PLAN.md),
the deferred-items ledger in [BACKLOG.md](BACKLOG.md). Where this doc names a
big feature (flight status, expenses), the detail lives in those docs — not
duplicated here.

Created 2026-07-23. Status keys: ✅ done · 🔄 in progress · ⏳ queued ·
🔑 owner-only · 🅿 parked (demand-gated).

---

## North star (current)

**The app is free; the only goal right now is adoption.** Deep-research
(2026-07-23) is blunt: App Store adoption is driven primarily by the
**ASO / featuring / localization track**, and only secondarily by shipping
polished "significant updates" to nominate around. So we run two tracks in
parallel — the **adoption track** (the real engine) and a **tight 1.3** (the
update we nominate). Basis: the 2026-07-23 deep-research report (featuring/ASO/
localization) + the Gen-Z targeting research (leverage is channel & copy, not UI).

---

## NOW — in flight

### Adoption track (the growth engine)
- [ ] 🔑 **Featuring nomination** — ASC featuring nomination form, type
  "App Enhancements"/"App Launch", ≥3 wks before a release (6–8 wks ideal).
  "Helpful Details" must call out **accessibility + uniqueness + localization**
  (Apple's editors weigh exactly these). *Pitch draft:
  [FEATURING_NOMINATION.md](FEATURING_NOMINATION.md); owner submits.*
- [ ] 🔑 **Product page rebuild + Custom Product Pages** (family vs friends) —
  Apple's data: **+2.5pp conversion (156% over the 1.6% default)**. Highest-ROI
  steady-growth lever. Then **Product Page Optimization** A/B tests (≤3 icon/
  screenshot/preview treatments).
- [ ] ⏳ **Metadata localization — Tier 1** (name/subtitle/keywords/description)
  for **es, de, fr, ja, pt-BR**. Cheap, no code; both an ASO win and a named
  featuring criterion. Install data picks which locales earn Tier-2 (in-app).
- [ ] 🔄 **Brand coherence** — landing dusk reconciliation **SHIPPED & LIVE**
  (PR #76). Follow-ups: **share page as a growth loop** (Tripto-branded,
  "make your own trip" CTA, clean OG cards for iMessage/WhatsApp/Stories —
  every shared trip is a free ad); mobile screenshot spot-check.

### 1.3 app — "finish the capture loop" (pure client, no backend, no new opex)
> Updates the 1.3 definition in PRODUCT_PLAN.md (owner-agreed 2026-07-23);
> a docs-sync should reconcile PRODUCT_PLAN's 1.3–1.4 mapping later.
Built in parallel. **No store build until fully ready + owner approval** —
iCloud/Xcode-Cloud build minutes are limited (see Constraints).
- [ ] 🔄 **G1 — Camera capture in the attach flow.** Camera source alongside the
  Photos/Files pickers. Needs `NSCameraUsageDescription`. Reuse the
  downsample→upload pattern (`ImageProcessing.downsampledJPEG`). Client-only.
  *(Sim has no camera — verify plumbing via unit tests + a real-device pass.)*
- [ ] 🔄 **F6 — Home-timezone setting.** User-set "home" zone (`@AppStorage`),
  threaded through `Trip+Bucketing.liveTimeZone(...)`, surfaced in `SettingsView`.
  Client-only.

---

## NEXT — 1.4 candidates

- [ ] **F1 — item `cancelled` status.** `itinerary_items.status` is a text CHECK
  `('suggested','confirmed')` (not a PG enum) → widen the check to add
  `'cancelled'`. **Trivial backend migration** + small app display. Pairs with
  the archive-import "Import anyway" recourse. Low demand — bundle when convenient.
- [ ] **F2 — draft / undated trips.** `trips.start_date`/`end_date` are NOT NULL
  + `check (end_date >= start_date)`. Needs drop-NOT-NULL + relaxed check **and**
  real app work for null-date UI (draft shape, home bucketing, empty states).
  **Moderate.**
- [ ] **G4 — Share extension.** New app-extension target + provisioning. Heaviest
  capture item; batch with F1/F2 so one backend + provisioning trip covers several.
- [ ] **iOS 26 Visual Intelligence image-search** — conform trip/itinerary
  entities to `.visualIntelligence.semanticContentSearch` so app results surface
  from camera captures & screenshots. **Standout differentiator, low incremental
  effort** (scan-to-add + App Intents already ship). Brand-new 2026 discovery
  surface almost no one is on.
- [ ] **Trip Live Activity** — "next item / trip countdown". Platform-tech depth
  is featuring currency (Flighty won a 2023 ADA for exactly this).
  `LiveActivityCoordinator` already exists (see ROADMAP §4.1).
- [ ] **Tier-2 localization** — full in-app via String Catalogs (`.xcstrings`)
  for the locales that convert from Tier-1.
- [ ] **Friends onboarding path** — surface `trip_type:friends` (already in schema,
  **zero backend**) as first-class. Gen-Z leverage.
- [ ] **Faster instant-value onboarding** — see a trip before sign-in (Gen-Z bail ~3.7s).

---

## LATER — big bets (post-adoption; product-direction call)

Detail lives in [ROADMAP.md](ROADMAP.md) Phase 4/5 and
[PRODUCT_PLAN.md](PRODUCT_PLAN.md). The fork: "slick real-time trip dashboard"
(flight status) vs "group-money-and-logistics hub" (expenses).
- [ ] **Expense split / tracking** — strongest friends-segment retention play
  (Splitwise-shaped gap). Large. → ROADMAP §5.
- [ ] **Real-time flight status** — the "magic" differentiator; carries **ongoing
  opex** (aggregator API). → ROADMAP §4.1 (staged plan already written).
- [ ] **Poll / vote on dates & destinations** (Troupe-style).
- [ ] Maps tab · discovery · document vault (BUILD_PLAN v2 / ROADMAP §5).
- [ ] **TikTok / UGC acquisition** (marketing, ongoing) — short demo videos +
  "share to story" loop; where Gen-Z discovery lives (~90% social, ~42–45% TikTok).

---

## Deliberately NOT doing (decisions + rationale)

- **Maximalist app reskin for Gen-Z** — breaks the accessibility floor and
  alienates the family buyer; Gen-Z's authenticity filter punishes reskins.
- **Reposition away from "families & groups"** — the "grandma → group chat" range
  IS the moat; broaden the funnel (friends path), don't narrow it.

---

## Constraints & gotchas (standing)

- **Store binaries: Xcode Cloud ONLY**, triggered by pushing a `v*` tag (or manual
  ASC start). **Build minutes are LIMITED** — only push a release tag when the
  release is *completely* ready **and** the owner approves. Never archive locally
  (owner's Mac runs beta Xcode ⇒ invalid binary).
- **Backend schema changes live in `~/repos/backend/projects/tripto/`** — owner-
  gated; never DDL from the app repo.
- **Quality bar on new UI:** full Dynamic Type incl. accessibility sizes,
  VoiceOver, Reduce Motion, AA contrast, 44pt targets, one `Design/Motion.swift`
  vocabulary, tokens only (no raw hex).

---

## Shipped / decided (log)

- **2026-07-22/23 — v1.2 approved & released.** Attachments, scan-to-add, on-device
  AI, viewer suggestions, Siri/App Intents. Privacy note recorded (PR #75).
  `v1.2-build50` marker tag held **local-only** (avoid a stray Xcode Cloud build).
- **2026-07-23 — Landing page brand reconciliation SHIPPED & LIVE** (PR #76):
  unicorn gradient → dusk/sunset (matches app icon + UI); rented Gen-Z slang →
  warm cross-gen copy; favicon fixed. Deployed to `tripto.navbytes.io`, verified live.
