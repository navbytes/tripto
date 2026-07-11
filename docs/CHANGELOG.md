# Changelog

All notable changes to Tripto are documented here. Format: [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Signature interactions & platform features (2026-07-11)

#### Added

**Signature interactions**
- Hero flight transition: card → trip screen shared-element animation (iOS 17 spring family; Reduce Motion → system crossfade; AX sizes → plain push).
- Physical boarding pass: scroll-based tilt effect (±3°, off under Reduce Motion), travel-day tear-off stub with haptic choreography (discovery nudge + progress ticks + settlement impact).
- Timeline now-line: amber hairline + indicator on today's itinerary, updating every minute. Past items de-elevated (shadow removed, icons dimmed) to avoid text-contrast regression; AA preserved by construction.
- Motion vocabulary: `Design/Motion.swift` frozen API — three spring families (snappy/standard/gentle) + haptics semantic map (success/warning/touch/tick/settle); animations migrate opportunistically.
- Empty-state art: four reusable vector scenes (home/itinerary/packing/bookings) composed from palette tokens + SF Symbols, dark-adaptive, no bitmap assets.

**Platform features (zero-opex, client-side)**
- WidgetKit (next-trip and today-plan widgets): `systemSmall`/`systemMedium`/`systemLarge` configurations, data via App Group `snapshot.json`, tap → trip deep-link.
- Live Activity + Dynamic Island: travel-day countdown (8h window) using `Text(timerInterval:)` for zero-push self-ticking; lock-screen banner, compact/minimal/expanded layouts.
- App Intents & Siri: "When's my next flight?" fixed-phrase shortcut (pre-launch discoverable), returns dialog without foregrounding; reads app-group snapshot.
- Core Spotlight: trips indexed by title + date range, cleared on sign-out; deep-link continuation routes through existing `AppRouter` path.
- App icon: programmatic 1024px master (dusk gradient + paper-plane glyph + contrail) + dark variant, script-generated and committed; honest ceiling — human designer pass recommended before App Store submission.

**Bookings definition fix**
- New `ItineraryItem.isBooking` predicate unifies confirmation-code detection: category in {flight, hotel, transport} OR any confirmation marker (code/ticketRef/reservationName). Bookings tab now shows all confirmed bookings regardless of prior partial filtering. Status-agnostic by design — exclusion of `suggested` items remains `TripView`'s query responsibility.

#### Fixed
- Data-layer resilience: per-row decode tolerance in pull-apply (one malformed row no longer aborts the sync), bounded retry with backoff on realtime subscribe failure.
- Delete-pass protection when sync decode skips rows (prevents silent deletion of server-originating data).
- FormTextField VoiceOver label: now reads visible caption, not placeholder text.
- CategoryIconTile scaling: icons now scale with adjacent text via @ScaledMetric.
- Confirmation-code copy button and paste-import pill: UX hit targets raised to 44pt; verification confirmed no default-size visual change.
- Flight boarding-pass header clipping at accessibility5: added vertical IATA/route stacking branch.
- Add-form category selector layout at accessibility5: added horizontal-scroll branch.
- ImportReviewBanner now appears on both Itinerary and Bookings tabs (was itinerary-only).

#### Verified
- 410 unit tests green (baseline 313 + new Motion/Intents/Bookings/LiveActivity tests), 6 UI tests green.
- Signature interactions: hero flight flawless at 60fps (frame-sequence verified), tear-off state survives app relaunch, now-line correct at section boundaries with perf acceptable on 14-day trips.
- Platform surfaces: widgets render via system logs (all 4 family configs), Live Activity self-ticks with zero updates, Spotlight indexing succeeds + cleared on sign-out, app shortcut pre-launch discoverable without launching app.
- Accessibility: hero/tear-off/now-line animations respect Reduce Motion; AX text sizes bypass animations; past-row de-elevation preserves WCAG AA contrast.
- App icon script: deterministic output across runs; icon + dark variant render correctly on home screen.
- Default text size and offline behavior remain unaffected.

---

## Prior releases

### [2026-07-08] Award quality pass (polish)

#### Added
- Full Dynamic Type support across all screens: icon scaling via @ScaledMetric, layout branches for accessibility5+ (flight header, add-form category selector, packing/timeline/home headers), 44pt touch targets for confirmation copy and paste-import pill.
- VoiceOver improvements: combined card elements for single-element speak, header traits on group headers, label/value/hint annotations on forms, action button hints.
- Reduced-motion guards on animations (SegmentedControl, Toast, PackingListView, ItineraryTabView).
- Success/warning haptics on item/trip saves and deletes.
- WCAG AA amber-text fixes (new amberInk palette token, reused across UI text).

#### Verified
- 313 unit tests green, 6 UI tests green (baseline 300 + 9 new).
- Live accessibility5 light/dark simulator drill: no truncation, no clipping, readable at all scales.
- Default text size remains pixel-identical (by construction: @ScaledMetric returns base value unchanged at default).
- Offline sync and delete-on-reconcile path end-to-end verified (tolerant decode + delete-pass protection).
