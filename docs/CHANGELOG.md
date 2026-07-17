# Changelog

All notable changes to Tripto are documented here. Format: [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Code quality — principles review & fixes (2026-07-17)

#### Changed
- **Internal quality pass across the app (no user-facing changes):** duplicated pure helpers single-homed in `Platform/Shared` (widgets no longer carry silently-drifting copies); share-link/invite writes moved from `ShareTripView` into `SyncEngine` with the standard `SyncBackoff`; the primary-CTA capsule and empty-state scaffolds extracted to `Design/Components` (9 + 4 sites); the email-import-address consent/retry state machine shared once (`ImportAddressLoader`, was hand-copied in 3 views); storage upload path/URL builders unified (`StorageBucketPaths`, preserving the RLS lowercase-uid rule).

#### Fixed
- **Same-day hotel handoffs across timezones no longer flag as "overlapping stays":** the conflict decision now compares real booked windows (check-in/checkout instants; a stay without a checkout claims only its check-in night from the actual check-in time) instead of midnight-expanded night labels. Kills the demo trip's Lisbon→Madrid false positive; genuine same-day double-holds still flag.
- **Outbox push order is now guaranteed:** ops carry a monotonic `seq` (pre-migration ties broken by `createdAt`), and trip-merge enqueues its shell-trip delete strictly after every repoint in one sequential chain — closing a latent reorder that could cascade-delete server-side children mid-merge.

#### Added
- **Share-link leakage regression tests:** the `ShareSummary` sanitizer is pinned by sentinel tests (confirmation codes, notes, emails, reservation names can never enter the public payload). Push-loop tests run deterministically (offline skips and sleep-based ordering removed); UI tests wait on real conditions (42 fixed sleeps → 8 justified survivors). Unit suite 938 → 949.

#### Added
- **Tripto Archive v1 — import & export:** Settings → "Import trips" accepts JSON archives from other apps or previous Tripto exports; deterministic on-device conversion, no AI/consent required, idempotent re-import via UUIDv5 deduplication. Settings → "Export trips" writes the same format for data portability. Time zone resolution per IATA airport tables, category-specific defaults; report shows summaries + skipped items with reasons. Spec: `docs/IMPORT_FORMAT.md` with LLM-conversion appendix for source-app migration. Unit test suite 509→610.
- **Email-import operations runbook:** `web/email-worker/RUNBOOK.md` consolidated go-live checklist (pre-flight, smoke test, post-MX verification). `scripts/check-golive.sh` automated health check.

### Tooling & release infrastructure (2026-07-12)

#### Added
- **SwiftLint** (shared canonical config with SpotHK): guarded local build phase; `swiftlint --strict` enforced in Xcode Cloud via `ci_post_clone.sh` with a version-pinned install (0.65.0).

#### Fixed
- **App Store version string now follows `MARKETING_VERSION`:** `CFBundleShortVersionString` was hardcoded to "1.0" in both app and widget plists, so version bumps would silently not ship. Both keys now bind to build settings; `MARKETING_VERSION` reconciled to the shipped "1.0".

### Email-import & calendar features (2026-07-12)

#### Added
- **Whole-trip calendar export:** "Add to Calendar" now exports the entire itinerary as a batch EKEvent operation, or as a shareable .ics file. Zero-opex, client-only, dates/times respect each item's local timezone.
- **Email-import consent gate:** forwarded emails are now consent-gated — users must explicitly tap "Continue" on a disclosure dialog (third-party AI, Cloudflare gateway, 7-day raw retention, code privacy) before revealing their import address. Shared dialog consistent across ItineraryTabView and ShareTripView.

#### Fixed
- **Calendar-permission crash:** app no longer crashes on devices without prior calendar access grant when attempting calendar export. Permission request is graceful and recovery is user-controlled.

### On-device import processing with user choice (2026-07-12)

#### Added
- **User-selectable import processing:** on iOS 26+ with Apple Intelligence, users can choose between on-device (default) or cloud AI processing via an in-sheet picker; the picker is only shown when a real choice exists (on capable devices).
- **Paste-import extraction runs on-device** by default on iOS 26+ with Apple Intelligence enabled (using Apple's built-in language model), keeping pasted text on the device and eliminating the privacy consent dialog for that path.
- **Rate limit messaging:** remote import path now enforces a 20/hr/user limit with a friendly, recoverable message ("try again in an hour").

#### Changed
- **AI consent dialog** appears only when remote import path is used (on-device path requires no consent).
- **Fallback re-confirmation** no longer references "devices without Apple Intelligence"; now offers "You can also switch to Cloud AI above" for clarity on devices with a choice.

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
