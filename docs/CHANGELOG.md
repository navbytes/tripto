# Changelog

All notable changes to Tripto are documented here. Format: [Keep a Changelog](https://keepachangelog.com/).

## [1.2] — 2026-07-22

### Siri & Shortcuts: ask and add by voice (2026-07-22)

#### Added
- **"Add ... to my packing list":** a Siri/Shortcuts action that adds an item to a trip's packing list (defaults to your current or next trip; a trip can be chosen). Works offline via the same sync queue as in-app adds; viewers get a polite refusal instead of a false success — the same permission rule as the app.
- **"What's my confirmation code for ...":** pick one of the current trip's bookings and Siri answers with its confirmation code — only after the device is unlocked, and the code itself never enters Spotlight, Siri suggestions, or the widget data file; it exists only in the spoken/shown answer.

#### Changed
- App version now 1.2 (`MARKETING_VERSION`) ahead of the next App Store submission.

### On-device AI: catch me up + packing suggestions (2026-07-22)

#### Added
- **"Catch me up" trip summary:** a menu action on the trip screen generates a short plain-language summary of the trip's saved plans — entirely on this iPhone (iOS 26+ with Apple Intelligence; the action simply doesn't appear elsewhere). Carries an explicit "summarized from your saved plans — check the itinerary for exact times" disclosure so generated prose is never mistaken for verified itinerary fact.
- **Packing suggestions:** "Suggest a starting list" on the packing tab (header + empty state) proposes practical items for the trip, on-device only. Nothing is ever added automatically — suggestions arrive as a pre-checked vetting checklist (same row UI as paste-import, now shared), deduplicated against the existing list and against themselves, inserted only via an explicit counted "Add N items".

#### Changed
- **Packing checklist checkboxes now meet the 44pt tap floor** (shared component — paste-import inherits the fix); generation failures offer an in-place "Try again" instead of a dead end.

### Website: "unicorn mode" landing redesign + SEO (2026-07-21)

#### Added
- **Landing page redesign (tripto.navbytes.io):** loud startup energy — night-violet hero with pink→purple→cyan gradients, sticker pills, a pure-CSS phone mockup, marquee strip, neo-brutalist feature cards, 3-step how-it-works, manifesto pull-quote, and a native `<details>` FAQ. Still zero JavaScript, strict CSP, system fonts only; all motion behind `prefers-reduced-motion`, small-text accents darkened to hold AA contrast.
- **SEO surface:** canonical URLs, Open Graph + Twitter cards with a generated 1200×630 `og.jpg`, JSON-LD `@graph` (Organization, WebSite, WebPage, MobileApplication, FAQPage mirroring the visible FAQ), `robots.txt` (disallows `/t/` + `/join/`), `sitemap.xml`, `llms.txt`, SVG favicon + touch icon. Privacy page picks up the brand hero, meta description, and canonical.
- **Asset pipeline:** `web/share-worker/scripts/generate-assets.mjs` renders the social card + touch icon via headless Chromium; images bundle into the Worker as wrangler `Data` modules.

#### Unchanged
- Token share pages (`/t/`, `/join/`) keep their calm dusk look, `noindex`/`no-store` posture, and sanitized payload — the redesign touches marketing surfaces only.

### Suggest a plan + on-device polish (2026-07-21)

#### Added
- **Viewers can suggest plans:** the add button becomes "Suggest a plan" for view-only members — the same add form, saving into the organizer's existing review inbox instead of straight onto the itinerary. Confirm/dismiss stays with organizers and companions; a viewer sees their own pending idea marked "Waiting for review". Enforced server-side (viewers can only ever insert suggestions attributed to themselves). Suggestions never appear on the public share link until confirmed.

#### Fixed
- **Attachment preview always closable:** the photo/PDF preview now carries Tripto's own floating close button (plus a drag indicator) — escape no longer depends on QuickLook's embedded chrome, which failed to show a Done button on device.
- **Booking-detail scroll no longer stutters:** the boarding-pass tilt and header sheen moved off a per-frame state channel onto SwiftUI's render-path `visualEffect` — the rubber-band bounce no longer re-renders the whole screen every frame (it had gotten heavier with 1.2's attachment strip). Same motion, Reduce Motion/accessibility behavior unchanged.
- **Suggest mode hides paste/email import entries:** a suggesting viewer could reach the paste flow whose packing branch the server rejects — the entries are hidden in suggest mode (mirrors the main screen), pinned by tests.

### Attachments & scan-to-add (2026-07-21)

#### Added
- **Per-booking attachments (photos & PDFs):** attach files to any itinerary item — a boarding pass, hotel voucher, or museum tickets live with the booking they belong to. Formats: JPEG/PNG/HEIC (re-encoded, ≈2400px quality 0.85 for crisp barcodes) and PDF (stored verbatim). Visible to all trip members; only uploader or organizer can delete. Attachments sync alongside items and cache locally after first view; items within the next 7 days prefetch on trip open (the airport-basement case). Caps: 10 files per item, 10 MB per file.
- **Scan-to-add for screenshots and PDFs:** turn a booking screenshot or airline PDF into a structured itinerary item — no competitor does this. Progressive OCR across iOS versions: iOS 26+ uses native `RecognizeDocumentsRequest` (on any chip); iOS 17–25 falls back to `VNRecognizeTextRequest`. Extracted text routes through the existing on-device/cloud AI pipeline (on-device by default on iOS 26+ with Apple Intelligence, cloud with named OpenAI consent elsewhere). Batches process serially with progress; unreadable items become friendly skipped rows. After extraction, users can attach the original screenshot or PDF to the created item — the import and its attachment land together, including cloud paths via `createdItemIds`.
- **Attachment viewing via QuickLook:** full-screen viewer with real file names (no UUID filenames), swipe through multi-attachment items.

#### Changed
- **Consent dialogs now name OpenAI:** four pre-transmission gates updated (two in paste-import + two in email-address entry). Scan-to-add variants state "the photo or PDF is read on this iPhone and only the extracted text is sent to OpenAI, routed through our Cloudflare gateway"; paste keeps its wording. Paste-import and email-address consent dialogs both name OpenAI concretely (was generic "third-party AI service").
- **Privacy disclosure updated:** `docs/PRIVACY_DISCLOSURE.md` updated to state the shared `LLM_MODEL` secret fact (paste and email use the same provider) and new dialog wording.

#### Fixed
- **Attachment cache wiped on sign-out:** `AttachmentStore.removeAll()` fires on `SyncEngine.wipeForSignOut()`, confirmed to cover delete-account (routes through `signOut()`). Cache is marked `.completeFileProtection` at rest (PII/codes) and excluded from backup (server is source of truth).
- **PDF render-bomb protection:** render pipeline caps to ~12MP hard pixel budget — hostile `/MediaBox` directives render safe, small bitmaps instead of unbounded ones.
- **Filename sanitization:** control characters stripped, length capped at 120 characters preserving extension.
- **MainActor data-integrity fix:** `AttachmentService.attach/delete/localFileURL` marked `@MainActor` to prevent SwiftUI-held `ModelContext` mutations off main. Assertion guards catch regressions in tests.

#### Verified
- Unit test suite: 1008 → 1026 tests, 0 failures, 3 pre-existing skipped.
- All new suites green: `AttachmentServiceTests` (15), `AttachmentStorageTests` (10), `AttachmentStoreTests` (11), `ItemAttachmentSyncTests` (10), `PDFTextExtractorTests` (1 hostile render), `IngestTextResponseDecodingTests` (2), `PasteImportSheetReviewTests` (4), extended `DTORoundTripTests` (+2), extended `ShareSummaryTests` (+1).
- Share-link sentinel tests confirm attachments never expose through public payload (structural: `ShareSummary.text(for:)` has no attachment parameter).
- Backend PRs: [navbytes/backend#17](https://github.com/navbytes/backend/pull/17) (schema + private `item-attachments` bucket, RLS membership-gated); [navbytes/backend#18](https://github.com/navbytes/backend/pull/18) (`ingest-text` returns `createdItemIds` for auto-attach).

## [Unreleased]

## [1.1] — 2026-07-17

### UX round — hero covers, Home avatar, profile layout (2026-07-17)

#### Fixed
- **Photo trip covers no longer bleed past the hero:** the cover photo painted under the sync banner and the Itinerary/Bookings/Packing tab row on every photo-cover trip (any text size), leaving tab labels on unpredictable photo pixels. The photo is now bounded to the hero exactly like gradient covers — tabs always sit on the paper background. (`CoverImage` bounds its photo internally; the hero call site mirrors its proposed frame.)
- **Home screen avatar now shows your profile photo** (and your chosen avatar color when there's no photo) — it previously drew a plain initials circle that predated photo support.

#### Changed
- **Settings → Profile relayout:** avatar sits beside a labeled "Display name" field; "Change photo" (now the app's standard capsule style) and "Remove" form a full-width action row under the avatar; the avatar-color row explains itself ("Shows on your initials when there's no photo"). The trip-member edit sheet keeps its existing layout.

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
