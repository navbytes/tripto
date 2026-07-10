# Changelog

All notable changes to Tripto are documented here. Format: [Keep a Changelog](https://keepachangelog.com/).

## [Unreleased]

### Added
- Full Dynamic Type support across all screens: icon scaling via @ScaledMetric, layout branches for accessibility5+ (flight header, add-form category selector, packing/timeline/home headers), 44pt touch targets for confirmation copy and paste-import pill.
- VoiceOver improvements: combined card elements for single-element speak, header traits on group headers, label/value/hint annotations on forms, action button hints.
- Reduced-motion guards on animations (SegmentedControl, Toast, PackingListView, ItineraryTabView).
- Success/warning haptics on item/trip saves and deletes.
- WCAG AA amber-text fixes (new amberInk palette token, reused across UI text).

### Fixed
- Data-layer resilience: per-row decode tolerance in pull-apply (one malformed row no longer aborts the sync), bounded retry with backoff on realtime subscribe failure.
- Delete-pass protection when sync decode skips rows (prevents silent deletion of server-originating data).
- FormTextField VoiceOver label: now reads visible caption, not placeholder text.
- CategoryIconTile scaling: icons now scale with adjacent text via @ScaledMetric.
- Confirmation-code copy button and paste-import pill: UX hit targets raised to 44pt; verification confirmed no default-size visual change.
- Flight boarding-pass header clipping at accessibility5: added vertical IATA/route stacking branch.
- Add-form category selector layout at accessibility5: added horizontal-scroll branch.

### Verified
- 313 unit tests green, 6 UI tests green (baseline 300 + 9 new).
- Live accessibility5 light/dark simulator drill: no truncation, no clipping, readable at all scales.
- Default text size remains pixel-identical (by construction: @ScaledMetric returns base value unchanged at default).
- Offline sync and delete-on-reconcile path end-to-end verified (tolerant decode + delete-pass protection).
