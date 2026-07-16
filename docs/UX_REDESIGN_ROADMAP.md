# Tripto — UX Redesign Adoption Roadmap

Drafted 2026-07-15 from the external UX mockups
([design/ux-redesign-2026-07/](../design/ux-redesign-2026-07/)) and the
code-verified review of them (what was stale, what's real, what's fenced).
[BUILD_PLAN.md](BUILD_PLAN.md) stays the product source of truth — Phase 5
amends its §4 Home spec in the same PR that changes the behavior.
[ROADMAP.md](ROADMAP.md) tracks the backlog program; this doc tracks the UX
program only. One phase = one PR, merged before the next phase starts.

Status keys: ✅ merged · 🔄 in progress · ⏳ queued.

**Standing quality gates (every phase):** hermetic `TriptoTests` green +
SwiftLint `--strict` clean locally before PR; context-isolated code review
(opus) clean; Dynamic Type incl. AX sizes, VoiceOver, Reduce Motion, AA
contrast, 44pt targets; motion only via `Design/Motion.swift`; colors only
via tokens. File adds go through `project.yml` + `scripts/bootstrap.sh`.

**Fenced out of this program** (backend schema or v2 scope — filed in
[BACKLOG.md](BACKLOG.md), not silently dropped): multi-stop trips, undated
trips, `ItemStatus.cancelled` + per-row "import anyway", cross-trip
traveller identity, suggestion/discovery cards, home-timezone setting,
FAB→contextual dock, de-systemising Settings' Form.

---

## Phase 1 — Itinerary rail: boarding-pass flights + timezone markers ✅ (PR #33)

The mockup's signature. Flights render as a compact boarding pass **in the
timeline row**; timezone changes become rail markers instead of floating
chip rows.

- **P1.1 Boarding-pass timeline row** for `category == .flight` (transport
  keeps its current row for now): carrier + flight number eyebrow, origin →
  destination as large Fraunces tabular codes, both **local** times with GMT
  labels under each, computed duration between, perforated footer carrying
  the existing landing note (`TZShiftChip.landingText`) when present. Built
  as a reusable component — Phase 3 embeds the same one in the add-flight
  form preview. Booking codes stay off the row (they live in
  `BookingDetailView`).
- **P1.2 TZ rail markers**: `TZShiftChipRow` restyles to a hairline break in
  the rail with an all-caps eyebrow ("BANGKOK TIME · GMT+7 · FROM HERE ON").
  One-time left-to-right draw-in per Motion vocabulary; static under Reduce
  Motion.
- **AX branch**: both elements restack legibly at accessibility type sizes
  (existing `TimelineLayout` pattern).

Surfaces: `Features/Trip/TimelineRowViews.swift`, `TimelineModels.swift`,
`ItineraryTabView.swift`, new `Design/Components/BoardingPassCard.swift`.
Data model untouched (`startsAt`/`endsAt`/zones already exist).
Tests: duration/+1d math, landing-footer presence, marker emission order.
Verify wave: tester, reviewer. Size: **M**.

## Phase 2 — Conflicts + trip chrome ✅ (PR #34)

- **P2.1 Stay-overlap detection**: pure function over a trip's lodging
  items (date-range intersection on `startsAt`/`endsAt`). Amber-wash banner
  at the top of the itinerary ("Two stays overlap all 6 nights" + "Review
  stays") and a clay flag line on each offending card. No persistence, no
  backend — recomputed from the live query.
- **P2.2 Hero title split**: eyebrow `DESTINATION · N DAYS` above the
  Fraunces title; kills the parenthetical wrap.
- **P2.3 Traveller filter compression**: `PersonFilterBar` drops the
  "Showing plans for" label; 56pt avatar-chip row.
- **P2.4 Trip-tz "today"**: liveness/today (`Trip+Bucketing`, itinerary
  auto-scroll) computed against the trip's item timezones (latest end tz,
  device fallback) so a trip stays live at 23:00 in Naha even if the phone
  already flipped days.

Surfaces: `Models/Trip+Bucketing.swift`, new `Models/StayConflicts.swift`,
`Features/Trip/{TripView,ItineraryTabView,PersonFilterBar}.swift`.
Tests: overlap matrix (full/partial/none/adjacent), bucketing tz cases.
Verify wave: tester, reviewer, ux-expert (timeline milestone: P1+P2
screenshots). Size: **M**.

## Phase 3 — Add-item sheet ✅ (PR #35)

Eleven stacked rows become one artifact; the form previews its own output.

- **P3.1** Type tiles get verb labels: Flight / Stay / Do / Eat / Ride.
- **P3.2** Flight route section renders the Phase 1 boarding-pass component
  live from the form fields — side-by-side airports, computed duration,
  timezone directly under each time, `+1d` badge anchored to the arrival
  time when it crosses midnight.
- **P3.3** Seat / terminal / gate / confirmation fold behind a disclosure
  with a one-line summary ("14C · T1 · QK7P2M").
- **P3.4** Assignee chips get a real selected state + one helper line:
  "Nobody selected means it's for the whole group."
- **P3.5** Paste-first: a banner at the top of the sheet opens the existing
  `PasteImportSheet` ("Paste a booking email — fills every field below").
- **P3.6** Sticky footer save (disabled until valid) + **"Save & add the
  return leg"** for flights (pre-fills the reversed route, +1 day, clears
  times/seat).

Surfaces: `Features/Trip/AddItemSheet.swift`, `AddItemFormSections.swift`.
Tests: return-leg construction, +1d detection, disclosure summary format.
Verify wave: tester, reviewer. Size: **M**.

## Phase 4 — Share, Settings, New-trip polish ✅ (PR #36)

- **P4.1 Share reorder** — people first, "Invite someone" primary; public
  link demoted to a switch-row with URL + copy + revoke (revoke exists);
  `ownRoleCard` deleted (your chip is on your row); role changed via inline
  chip menu on the row (replaces the separate sheet); no-account profiles
  labeled **Traveller** in the same list (unified `PersonRow` already
  exists).
- **P4.2 Email-import entry moves** from ShareTripView to the Add sheet's
  paste banner area (same consented `ImportAddressCard`, same disclosure
  copy) — getting data in ≠ getting people in.
- **P4.3 Settings** — "Coming from another app?" becomes a featured card
  (conversion prompt is the product's most distinctive feature); Export row
  states real counts ("20 trips · 67 items"); Account section demoted below
  data; system Form styling stays.
- **P4.4 New-trip** — cover picker becomes destination-seeded gradient with
  a shuffle button (replaces three unexplained circles); "Start from a
  booking email instead" secondary entry. Trip-type row stays.

Surfaces: `Features/Share/ShareTripView.swift`,
`Features/Settings/SettingsView.swift`, `Features/Home/TripFormView.swift`,
small `AddItemSheet` touch (after Phase 3 lands — sequential, no conflict).
Verify wave: tester, reviewer, **security-auditor** (roles/link surface).
Size: **M**.

## Phase 5 — Home: one list, three registers ✅ (PR #37)

The biggest IA change; amends BUILD_PLAN §4 in the same PR.

- **P5.1** Tabs removed. One list: everything ending today-or-later,
  soonest-start first; then everything past, most recent first. One
  comparator, no special cases — a live trip lands at position 0 on its
  own. `HomeInitialTab` retires.
- **P5.2 Register "next"** (nearest upcoming trip only): full card +
  countdown ring on the "in N days" pill + "FIRST UP · JL901 · HND → OKA ·
  Wed 09:40" strip from the trip's first upcoming item.
- **P5.3 Register "now"** (live trip): "Day 3 of 5" pill; today's first two
  items + "+N more today" inline on the card; tap lands on **today** in the
  itinerary (auto-scroll exists).
- **P5.4 Register "been"**: muted compact rows — no gradient, no avatars,
  no countdown — under sticky year headers, behind a "BEEN THERE · N TRIPS"
  section header. Swipe → "Copy to a new trip" (existing `TripDuplication`).
- **P5.5** Launch always opens at the top; "Plan a new trip" row closes the
  list.

Surfaces: `Features/Home/HomeView.swift`, `TripCard.swift`, new register
components, `HomeInitialTab.swift` (delete), `docs/BUILD_PLAN.md` §4.
Tests: comparator (upcoming asc / past desc / live-first), register
selection, first-item lookup.
Verify wave: tester, reviewer, **qa-verifier** (acceptance on device flows),
**ux-expert** (register hierarchy screenshots). Size: **L**.

## Phase 6 — Post-import trust suite ✅ (PR #38; P6.5 covers+toggle #39, P6.6 row move #40)

What the archive/email import produces, made trustworthy.

- **P6.1 Branded import-result sheet** for Settings' archive import
  (replaces the plain report alert): Fraunces headline, stat tiles (trips /
  items / travellers, tabular numerals), skipped rows listed each with an
  app-side recourse where one exists, plain-language notes for the rest.
  One primary action: "See your N trips".
- **P6.2 Duplicate-trip merge**: detection (identical date range + same
  destination) renders the mockup's fused strip on the **second** card
  ("Same dates as the trip above · Merge"); merge moves items + profiles
  into the survivor, deletes the shell, 6s undo toast per Motion.
- **P6.3 Traveller dedupe (within trip)**: post-import prompt when a trip
  holds profiles sharing a normalized name/email; review & merge sheet.
  Cross-trip identity → BACKLOG (needs a person entity, backend).
- **P6.4** BACKLOG.md entries for every fenced item this program touched.

Surfaces: `Features/Settings/SettingsView.swift` (+ new
`ImportResultSheet.swift`), `Features/Home/HomeView.swift` (merge strip),
`Models/` (merge + dedupe helpers, app-side only).
Tests: dup detection matrix, merge item/profile reassignment + undo,
dedupe normalization.
Verify wave: tester, reviewer, **security-auditor** (merge touches shared
trip data + RLS assumptions), qa-verifier. Size: **L**.

## Phase 7 — Award audit + fix cycle ✅ (fix PRs #41–#43, #45–#46; verdict: SHIP, 11/11 verified fixed, 0 regressions. Images program: P8-0 backend, P8a avatars #44, P8b photo covers #49, P8c Pexels search #50 — complete)

1. Build the app in the simulator; capture the full screen set (light +
   dark, default + AX type sizes) to `.claude/company/ux-redesign/handoffs/`.
2. UX expert pass with an Apple-Design-Award-caliber brief across the whole
   app — hierarchy, motion, copy, consistency, accessibility.
3. CTO triages findings: accept / decline with logged reasons.
4. Accepted findings → fix PR(s) (`ux/p7x-*`), same gates as every phase;
   changed screens re-audited.
5. Repeat 2–4 until no open high-priority findings. Final report.

---

## Order & dependencies

```
P1 (pass component) ──► P3 (form embeds it)
P2 (bucketing tz fix) ─► P5 (registers use buckets)
P3 ──► P4 (both touch AddItemSheet — sequential)
P1..P6 ──► P7 (audit the finished surface)
```

Phases land strictly in order; each is one squash-merged PR on `main`.
