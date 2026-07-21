# Tripto 1.2 Release — App Store Submission

**Release date:** 2026-07-22  
**Build:** 1.2 (MARKETING_VERSION)

---

## What's New (App Store copy)

Turn that hotel screenshot or boarding pass PDF straight into a shared itinerary item — no typing. Tripto 1.2 adds scan-to-add: select a photo or PDF, Tripto reads it on your phone, and out pops a structured booking you can refine and share with your group.

Then attach the actual ticket to the item. Keep hotel vouchers, baggage stickers, museum PDFs, and confirmation codes right where you need them — with the booking itself, not buried in Mail or Files. All files sync to companions and viewers; only you or the organizer can remove them.

Viewers can now suggest plans (a flight, a dinner, a museum day) without editing the main itinerary. Your ideas go straight to the organizer's review queue — they confirm or dismiss, you see the status.

On iPhones with Apple Intelligence, ask Siri to read your itinerary ("What's on my trip?") or add to your packing list by voice. Say "Add sunscreen to my packing list" and it's there — same permissions as the app, offline-capable. Ask for a booking confirmation code and Siri whispers it only when your phone is unlocked.

Trip summaries and packing suggestions arrive on-device (no cloud, no consent) if you have Apple Intelligence. A tap generates a plain-language rundown of your plans or proposes practical packing items — you always review before adding.

Throughout: your booking data never leaves your phone unless you share it. Screenshots, PDFs, all extracted text — read on-device first, sent to the cloud only if you choose, routed through Cloudflare for privacy.

**What was new in 1.1:** photo covers for trips, shared packing lists with per-person assignment, widget, Live Activity countdown, app-launch Siri shortcut ("When's my next flight?"), Spotlight indexing, WidgetKit and Home screen photo avatar.

---

## Promotional Text (for App Store listing refresh)

**Current (1.1):**  
Turn scattered bookings into one shared, at-a-glance itinerary — built for families and groups, not just solo business trips.

**Proposed 1.2 refresh:**  
Turn scattered bookings into one shared itinerary, with your boarding pass photos and vouchers attached — everything stays private on your phone unless you share.

**Rationale:** Lead with the privacy angle (the structural differentiator vs. TripIt/Wanderlog) and the attachments feature (the table-stakes gap Tripto just closed). Keep it scan-line length (~170 chars), same tone.

---

## Owner Console Checklist

Steps to submit Tripto 1.2 to App Review and release:

### Pre-submission (tech)

- [ ] Verify `MARKETING_VERSION` is set to `1.2` in `project.yml`
- [ ] Build the Release archive in Xcode Cloud (committed to commit hash; tag optional)
- [ ] Verify App Privacy labels in App Store Connect:
  - [ ] No new data types added in 1.2 (attachments use existing Supabase storage disclosure; on-device AI paths add no tracking)
  - [ ] Consent dialogs still name OpenAI (checked: paste-import, scan-to-add cloud path, email-import — all updated in CHANGELOG)
  - [ ] "Photos or Videos" **not needed yet** (P8 avatar/cover is 1.3 — this 1.2 has no new photo upload from users)
  - [ ] Leave all other fields from 1.0 submission unchanged

### Submission (App Store Connect)

- [ ] Upload Build (Xcode Cloud → App Store Connect auto-delivery, or manual upload)
- [ ] Paste "What's New in Version 1.2" text (see above; plain text, no markdown; 4000 char limit — our version is ~2000)
- [ ] Consider refreshing promotional text (use "Proposed 1.2" above or own wording; 170 char limit)
- [ ] Screenshots: can reuse 1.0 set (they show the feature set, not the 1.2 specifics); if desired, regenerate per `RELEASE_READINESS.md` §7
- [ ] Submit for Review

### Post-approval (manual release + docs)

- [ ] App Review approval → manually release to App Store (not automatic; gated on backend readiness for previous releases; no backend changes in 1.2, so safe to release immediately after approval)
- [ ] Tag commit with `v1.2-build<N>` (where N is the build number visible in App Store Connect)
- [ ] Email privacy note: "1.2 ships privacy-improving on-device AI and scan-to-add for bookings; no new data collection. Attachments use existing Supabase storage (RLS-gated). On-device paths add zero tracking."

### Privacy + compliance recheck

- [ ] Privacy labels: confirm no "Photos or Videos" added (deferred to 1.3 when P8 user photo upload ships)
- [ ] Consent wording: all dialogs mentioning cloud AI now explicitly name OpenAI (confirmed in 1.2 CHANGELOG)
- [ ] No new SDKs, no new third parties
- [ ] Privacy policy live at tripto.navbytes.io/privacy (already updated post-1.1)

### Known details (for reference, not to-do)

- **No backend migration:** attachments schema + policies live in backend repo (PRs #17/#18, already deployed in 1.2 development)
- **Keychain session remains:** signed Release build required for Supabase writes (anon key fallback = `42501` error, looks like RLS but is auth missing)
- **Local test before submission:** run `-uitestAutoSignIn` once on device simulator to verify auth/sync round-trip; see `TESTING.md`
- **No external share extension in 1.2:** upload pickers (Photos/Files/Camera) exist in-app; browser/mail share extension deferred to 1.3 (provisioning + new target complexity)

---

## Decision log

**Release version:** 1.2 subsumes both Attachments (original 1.2) + Siri + On-device AI + Suggest + Website (originally Unreleased), dated 2026-07-22.  
**Build infrastructure:** Xcode Cloud builds remain the norm; manual archive upload also supported if needed.  
**Privacy stance:** On-device-by-default messaging (iOS 26+ Apple Intelligence paths carry zero consent and zero cloud), with cloud paths explicitly disclosed and named.  
**Marketing angle:** privacy + functionality (scan-to-add, attachments) over "more features." Positioning is "your data, your device, only shared by you" vs. competitors' server-first models.
