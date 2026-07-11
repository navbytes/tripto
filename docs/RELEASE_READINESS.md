# Tripto — App Store release readiness

Living checklist to take Tripto from "feature-complete" to "submitted." Status
keys: ✅ done · 🔄 in progress · ⏳ queued (I can do it) · 🔑 **owner-only**
(needs your Apple account / credentials — I cannot do these autonomously).

Last updated: 2026-07-11 (award signature layer shipped).

---

## 0. The critical path (read this first)

Everything below is achievable by me **except one gated dependency**: a paid
**Apple Developer Program** membership ($99/yr) and the Apple-console setup that
hangs off it. Without it, three things cannot happen: a signed distribution
build, **Sign in with Apple in production**, and the actual App Store Connect
submission. I will get the app to "archive-ready, pending your Apple account,"
and hand you an exact click-by-click list (§6). Nothing else blocks.

Second-most-important: **production auth is Sign in with Apple**, and research
(RESEARCH_FINDINGS §1.1) found a live Supabase bug where hosted projects can
500 on the Apple token path. De-risked: the Supabase Apple provider is enabled
+ verified, and this project runs GoTrue **v2.192.0** (> v2.177.0, the fix), so
that 500 can't hit us; a real device sign-in confirms it.

---

## 0.4 New surfaces added (2026-07-11)

The app now ships three new capabilities requiring App Store Connect setup:

1. **Widget extension** (next-trip + today-plan widgets, Live Activity): requires **App Group entitlement** registered on your Apple Developer account + provisioning profile rebuild. The app target now includes the `io.navbytes.tripto.widgets` bundle; see §0.7 for the provisioning details.
2. **Live Activity** (travel-day countdown on lock screen / Dynamic Island): requires `NSSupportsLiveActivities = true` in the app's Info.plist (already set).
3. **App Intents** (Siri "next trip" shortcut): pre-launch discoverable from compiled metadata; no registration step needed.

**App Group security model:** `snapshot.json` in the shared container carries sanitized trip/item data only (no confirmation codes, notes, emails, or coordinates). The SwiftData store remains app-sandbox-only. On sign-out, `SnapshotWriter.clear()` deletes the snapshot, reloads widget timelines, wipes the Spotlight index, and ends any running Live Activity — so no surface retains the previous account's trip. (The security audit's one low-severity finding, that Live Activities weren't ended at sign-out, was fixed before merge.)

---

## 0.5 Where we are (2026-07-11 evening) — and your exact next steps

**Done autonomously — nothing needed from you:**
- Whole app **M0–M6**, committed, **411 unit + 6 UI tests** (0 failures).
  Release-hardened: app icon
  (light + dark variant, script-generated), branded launch screen, version 1.0.0,
  anon-auth compiled out of Release, **Release build verified clean**.
- **M6 wave 1 + wave 2** (award signature layer): hero flight, physical boarding
  pass (tilt + tear-off), timeline now-line, motion + haptics vocabulary, empty-state
  art, WidgetKit (2 widgets), Live Activity + Dynamic Island (zero-push countdown),
  App Intents (Siri shortcut), Core Spotlight indexing, programmatic app icon,
  **bookings definition fix** (unified `isBooking` predicate). All surfaces pass AX
  bar (Reduce Motion, Dynamic Type, VoiceOver, AA contrast). **Security audit clean**
  (data minimization verified field-by-field; its one low-severity finding — Live
  Activities not ended at sign-out — fixed before merge).
- **Post-audit hardening (2026-07-09):** permanently-failed syncs shown to user,
  flights validate arrival-after-departure.
- Backend live: schema + RLS + RPCs; **Sign in with Apple provider enabled +
  verified**; the fix I flagged is present (GoTrue v2.192.0).
- Web (all live): share page, **privacy policy**, **root landing page**
  (Marketing + Support URL), **AASA** for universal links, **daily keep-alive
  cron** (kills the free-tier-pause risk).
- **Account-deletion token revocation** (5.1.1(v)): `apple_refresh_tokens` table
  + `apple-link-token` + `delete-account` edge functions **deployed**; the app
  is **wired** to call them; **`delete-account` verified end-to-end** (throwaway
  user → 204 → auth.users + profile gone). Only the Apple `/auth/revoke` call
  itself is unverified — it needs a real device sign-in + your `.p8`.

**Your steps when back — each genuinely needs your Apple account / device:**
1. **Device Sign-in-with-Apple test** (§0's Step 4): run on a real device, tap
   Sign in with Apple, confirm you land on the trip list.
2. **Add the `.p8` secret** (NOT set yet — verified):
   `cd ~/repos/backend/projects/tripto && supabase secrets set APPLE_SIWA_PRIVATE_KEY="$(cat /path/to/AuthKey_5YX6JK6K9A.p8)"`
3. **Verify delete-with-revoke on device**: delete a throwaway account from
   Settings; it should sign you out cleanly (revoke now fires with the secret).
4. *(Optional)* **Universal links**: enable the **Associated Domains** capability
   on the App ID (same console as SiwA), tell me, and I add the entitlement
   (`applinks:tripto.navbytes.io`) — the AASA is already served. Custom scheme
   `tripto://` works without this.
5. **App Store Connect**: create the app (bundle `io.navbytes.tripto`); paste
   metadata (§7), screenshots (`/tmp/appstore-*.png`, 6.9"), App Privacy (§4).
6. **Xcode**: Product → Archive → Distribute → App Store Connect → upload → submit.
7. **Pre-submission**: disable backend anonymous sign-ins (§3) + purge the
   accumulated anonymous test trips.

---

## 1. Functional completeness (the build)

| Milestone | Status |
|---|---|
| M0 backend schema + RLS + RPCs; app foundations | ✅ committed |
| M1 local-first data, auth gate, trip CRUD, home | ✅ committed |
| M2 timeline, item CRUD, booking detail, OS handoffs | ✅ committed |
| M3a no-app share web page (live at tripto.navbytes.io) | ✅ deployed |
| M3b in-app collaboration, invites, roles, account deletion | ✅ committed |
| M4 family layer (profiles, "Just mine", packing) | ⏳ |
| M5 offline hardening + a11y + perf pass | ✅ committed |
| **M6 signature interactions + platform layer (widgets/Live Activity/Intents/Spotlight)** | ✅ **shipped 2026-07-11** |

## 2. Submission apparatus

| Item | Status | Notes |
|---|---|---|
| App icon (1024, no alpha) | ✅ | **script-generated + dark variant** (gen_appicon.swift); both wired in Contents.json; compiles into Release build. Human designer pass recommended pre-submission. |
| Launch screen (branded) | ✅ | `LaunchBackground` colorset (paper/ink), no white flash — Apple-idiomatic (no splash imagery) |
| Privacy manifest `PrivacyInfo.xcprivacy` | ✅ | UserDefaults CA92.1; tracking=false; collected types declared. §4 — **snapshot data minimization verified** (no codes/notes/emails/coordinates in platform surfaces). |
| Hosted privacy policy | ✅ | **live at https://tripto.navbytes.io/privacy** (Worker /privacy route) |
| App Privacy "nutrition labels" | ⏳ draft | §4 — fillable copy ready for App Store Connect |
| Release-build hygiene (DEBUG gating) | ✅ | all test surfaces `#if DEBUG`; anon-auth compiled out of Release; **Release config builds clean** (verified). One pre-submission flip left: disable backend anon sign-ins once testing's done. §3 |
| Encryption compliance | ✅ | `ITSAppUsesNonExemptEncryption = false` (standard TLS only) |
| Permission usage strings | ✅ | Calendar ✅ (`NSCalendarsUsageDescription`); no location/photos/contacts prompts (MKLocalSearchCompleter needs none) |
| Account deletion (5.1.1(v)) | ✅ | `delete-account` edge fn (revoke-then-delete) deployed + **verified end-to-end**; app wired. Apple `/auth/revoke` awaits device + `.p8` |
| Sign in with Apple entitlement + provider | ✅ app / 🔑 device | entitlement in project.yml; Supabase provider enabled + verified (GoTrue v2.192.0). Remaining: device sign-in test |
| Screenshots (6.9") | ✅ | 1320×2868 set captured (timeline, boarding pass, share) in /tmp/appstore-*.png + milestone captures; owner may reframe/caption |
| App Store Connect metadata | ⏳ draft | §7 — ready to paste |
| Distribution archive + upload | 🔑 | needs signing team; §6 |

## 3. Release-build hygiene (audit before archiving)

Must be `#if DEBUG`-only, never in a Release build:
- Anonymous sign-in and the "Continue (test account)" button on WelcomeView.
- The `-uitest…`/`-simulateOffline` launch-argument autopilot hooks.
- `DemoSeeder` and any "Seed demo trip" menu.
- Any access-token `print()` used in verification drills.
- The email-OTP fallback sign-in.

**Audit done 2026-07-08 (read-only pass; fixes belong to the M6 hardening
milestone).** ✅ All *user-reachable* test surfaces are correctly `#if DEBUG`-
gated: the "Continue (test account)" button, the "Seed demo trip" menu, every
`-uitest*` hook, `DemoSeeder` (whole file), and `UITestBridge` (whole file).
No test UI ships in Release. Minor **dead-code cleanups** to make in M6 (inert
in Release — unreachable, but should not be in the shipping binary):
- `AuthManager.signInAnonymously()` — wrap in `#if DEBUG` (only DEBUG callers).
- `WelcomeView.signInAnonymously()` private wrapper — same.
- `TripView.uitestBookingDetailItemId` property + its `if let` use in the body
  (lines ~66/127) — gate the property too, not just the setter.
- `SyncEngine`'s `-simulateOffline` argument check (line ~61) — gate it
  (harmless: App Store launches can't pass arguments, so it never fires).
**Backend hardening (more important):** `enable_anonymous_sign_ins = true` is on
purely for the DEBUG test path. v1 exposes no anonymous feature, so **disable it
on the backend before launch** (config.toml in the backend repo → `config push`)
to shrink the auth attack surface — anonymous sign-in is production auth's job
via SiwA only.

Release build must: archive under the Release config with no simulator-only
code, `SWIFT_ACTIVE_COMPILATION_CONDITIONS` excluding DEBUG, a real
MARKETING_VERSION (1.0.0) + CURRENT_PROJECT_VERSION (1), and the app icon +
launch screen present. A dedicated agent audits this in M6 and runs
`xcodebuild -scheme Tripto -configuration Release archive` (unsigned is fine to
prove it compiles; a *signed* archive is owner-gated).

**Verification gotcha (cost 3 agents hours — see memory):** any drill that
exercises authenticated writes must use a **signed** build. supabase-swift keeps
the session in the Keychain, which is absent in a fully-unsigned build → session
not persisted → writes fall back to the anon key → `42501`. It masquerades as a
broken RLS policy. Proven both ways by `TriptoTests/LiveAuthWriteTests`
(`TRIPTO_LIVE_TESTS=1`, passed via `TEST_RUNNER_…`): fails unsigned, passes
signed. Production (TestFlight/App Store) is always signed, so it's a
verification-only trap. **Pre-launch:** purge the accumulated anonymous test
trips from the DB (harmless, RLS-isolated, but tidy up before real users).

## 4. Privacy — what Tripto collects (for the manifest + labels)

**Data linked to the user's identity:**
- **Contact info** — email + name from Sign in with Apple (email may be an
  Apple private-relay address). Purpose: app functionality (account, invites).
- **User content** — trips, itinerary items (incl. locations, confirmation
  codes, notes), packing lists, trip-member profiles. Stored in Supabase
  (Postgres) under the user's account, protected by RLS. Purpose: app
  functionality; shared only with trip members the user invites, and — for
  items the user share-links — a **sanitized** subset (no codes/notes/emails)
  on the public page.

**Not collected:** no tracking, no analytics/ads SDKs, no location tracking
(location text/coords are user-entered content, not device tracking), no
third-party data sharing. **App Privacy → Tracking: No.**

**Required-reason APIs (`PrivacyInfo.xcprivacy`):**
- `NSPrivacyAccessedAPICategoryUserDefaults` → reason **CA92.1** (access to
  the app's own stored values: waitlist tap count, last-used time zones).
- `NSPrivacyTracking` = false; `NSPrivacyTrackingDomains` = []. Verify
  supabase-swift ships its own manifest (recent versions do); if not, cover its
  required-reason usage here too.

## 5. Account deletion & Sign in with Apple (compliance detail)

Guideline **5.1.1(v)**: an app with account creation must offer in-app
deletion. **Built and deployed** (2026-07-08):

- **App:** Settings "Delete account" → `delete-account` edge function. At
  sign-in, `WelcomeView`/`AuthManager` capture Apple's `authorizationCode` and
  (best-effort) POST it to `apple-link-token`.
- **Backend (navbytes/backend):** `apple_refresh_tokens` table (edge-only,
  deny-all RLS); `apple-link-token` exchanges the code → stores a refresh token;
  `delete-account` best-effort-revokes via Apple `/auth/revoke` then
  `admin.deleteUser` (cascades all data). Client secret is an ES256 JWT signed
  with the `.p8` (team `59J9RQXYYP`, key `5YX6JK6K9A`, bundle `io.navbytes.tripto`).
- **Verified:** `delete-account` live end-to-end (throwaway user → 204 →
  auth.users + profile rows gone). App builds + 187 tests green.
- **Remaining (device + owner):** set `APPLE_SIWA_PRIVATE_KEY` (the `.p8`) as a
  Supabase secret — *not set yet*; then a real device sign-in exercises the
  code-exchange + the Apple revoke. Deletion (the core requirement) already works
  regardless; a missing secret just skips the revoke.

## 6. 🔑 Owner-only actions (I cannot do these — they need your Apple account)

**Apple Developer account: ✅ owner has one (textnav@outlook.com).** Enrollment
blocker cleared. The steps below still need *your authenticated access* to that
account's Developer console + App Store Connect — I can't log in as you.
**Team ID: `59J9RQXYYP`** (provided 2026-07-08; not secret). Wired at the
SiwA/signing milestone into: the associated-domains entitlement + signing team
(project.yml), the Worker's AASA `APPLE_TEAM_ID` var, and the Supabase Apple
provider — deferred until then so it doesn't collide with in-flight work.

1. ✅ ~~Enroll in the Apple Developer Program~~ — done (textnav@outlook.com).
2. **App ID**: create/confirm `io.navbytes.tripto` with the **Sign in with
   Apple** capability enabled + **App Groups** capability for `group.io.navbytes.tripto`.
3. **Provisioning profile**: regenerate the automatic provisioning profile for
   the app ID after enabling App Groups (Xcode or Developer console). Both the
   main app and the `io.navbytes.tripto.widgets` extension target must have the
   App Group entitlement.
4. **Sign in with Apple key**: create a Key (.p8) with SiwA enabled; note the
   **Key ID** and your **Team ID**. Send me the Key ID + Team ID (NOT the .p8
   contents in plaintext here — you'll add the .p8 as a Supabase secret / GitHub
   secret yourself). Needed for token revocation (§5) and the Supabase provider.
5. **Supabase Apple provider**: in the backend repo I'll set
   `[auth.external.apple] enabled = true, client_id = "io.navbytes.tripto"` and
   push it; you confirm it in the dashboard. (I can do the config push; you
   verify.)
6. **Associated domain** (optional, for universal links): add the Team ID to the
   Worker's `APPLE_TEAM_ID` var (I redeploy) and I'll add the
   `applinks:tripto.navbytes.io` entitlement + pin the signing team in
   project.yml. Custom-scheme `tripto://` invites work without this.
7. **App Store Connect record**: create the app (name "Tripto", bundle id,
   primary language), fill metadata (§7 — I draft it), upload screenshots
   (I generate), answer App Privacy (§4), set price = Free. In the TestFlight
   section, ensure the **TestFlight builds include the embedded extension** —
   confirm `TriptoWidgets` is listed under "Included Bundles" when uploading
   the archive.
8. **Archive & upload**: with the signing team + App Group provisioning finalized,
   Product → Archive in Xcode (or `xcodebuild archive` + Transporter) → upload →
   submit for review.

Also budget the **free-tier pause** decision (RESEARCH_FINDINGS #6): a paused
Supabase project makes the app + share links go dark between trips. Before real
users, either add a keep-alive ping or move to Pro ($25/mo).

## 7. App Store Connect metadata (draft — ready to paste)

- **Name:** Tripto
- **Subtitle (30 char):** Trips your whole group sees
- **Category:** Travel (primary); Productivity (secondary)
- **Age rating:** 4+
- **Price:** Free
- **Promotional text (170):** Turn scattered bookings into one shared, at-a-glance
  itinerary — built for families and groups, not just solo business trips.
- **Keywords (100):** trip,itinerary,travel planner,family trip,group travel,
  vacation,packing list,shared itinerary,flights,booking
- **Description (draft):**
  > Tripto turns everyone's scattered bookings into one shared itinerary the
  > whole group can see — even the people who never install the app.
  >
  > • A day-by-day timeline that shows each flight, stay, and plan in its own
  >   local time, so a late-night arrival is never misread.
  > • Boarding-pass detail cards with confirmation codes, one tap to add to
  >   Calendar or get directions.
  > • Invite family with a link — companions can add plans, viewers just watch,
  >   and grandparents can open a read-only web link with no app and no account.
  > • A shared packing list you can assign to each person, and a "Just mine"
  >   filter so everyone sees what *they* need.
  > • Works offline — read the whole trip and make edits on the plane; they sync
  >   when you land.
  >
  > No ads. No tracking. Your trip is shared only with the people you invite.
- **Support URL:** https://tripto.navbytes.io (add a support/contact section)
- **Marketing URL:** https://tripto.navbytes.io
- **Privacy Policy URL:** https://tripto.navbytes.io/privacy
- **Copyright:** © 2026 navbytes
- **App Review notes (paste into the "Notes" field):**
  > Sign in with Apple is the only sign-in method — no username/password and no
  > demo account are needed; please sign in with your own Apple ID.
  >
  > Quick tour: after signing in, tap "Plan a new trip"; open it and use the ＋
  > to add a flight/stay/activity; tap the share icon (top-right) to see the
  > collaboration screen — you can generate an "anyone-can-view" link that opens
  > a read-only itinerary in any browser with NO app and NO account (e.g.
  > https://tripto.navbytes.io/t/… — booking codes and notes are stripped), and
  > role-carrying invite links for companions/viewers.
  >
  > Account deletion is in Settings (tap the avatar, top-right of Home) →
  > "Delete account"; it permanently deletes the account and revokes the Apple
  > token. The app works offline (reads + optimistic edits that sync on
  > reconnect). No third-party tracking or ads.
- **Demo account:** not required (Sign in with Apple).

## 8. Remaining risks (from research, carried here)

- SiwA-on-Supabase issuer 500 — test against this project once the App ID
  exists; DEBUG OTP fallback keeps dev unblocked.
- Free-tier pause — **MITIGATED**: a daily Cloudflare cron (`0 9 * * *` on the
  share Worker) pings Supabase so the project never idles into a pause.
  Deployed + verified. Revisit Pro ($25/mo) only if real traffic ever warrants
  always-on guarantees.
- Name proximity to TripIt/Tripoto — accepted at personal scale; low rejection
  risk, non-zero. (Owner decided to keep "Tripto".)
- iCloud+ mail has no inbound API — only matters for the v1.5 email-import
  feature, out of v1 scope.

## 9. M5 (offline · a11y · perf) outcomes — done in the main loop

The subagent spawner stalled three times mid-session (dead-at-launch), so M5 was
executed directly rather than delegated. What was verified/changed:

- **Reduced motion: ✅ already honored** and confirmed — SegmentedControl (tab
  underline), Toast (transitions), TripView all gate animations behind
  `@Environment(\.accessibilityReduceMotion)`.
- **VoiceOver: improved on the primary screens** — `TripCard` (was unlabeled →
  now one spoken summary: title, country, countdown, duration, travellers,
  pending); timeline rows (`TimelineCardRow`) now a single element that *names
  the category* (previously conveyed by node colour + icon only) plus
  title/subtitle/time/zone/tags/status. Booking detail's confirmation copy
  button already had a hint. 44pt targets + gradient contrast came from the
  design system and hold.
- **Logging hygiene: ✅ clean** — no `print`/`os_log` emits confirmation codes,
  tokens, emails, or notes (grep-verified); the one debug `print` is DEBUG-gated.
- **Performance:** timeline rows are Equatable value snapshots (`.equatable()`),
  so unrelated `pendingRowIds` changes don't re-render cards. `dayModels`
  rebuilds per render but is sub-ms at family scale (≤~43 items); left as-is with
  this note rather than adding `@State` caching risk. PersonFilter recompute
  (M4-flagged) is likewise fine at scale.
- **Offline:** architecture is M1's local-first SwiftData mirror + outbox;
  behaviour is unit-proven (coalescing, pending-row protection, idempotent
  upserts, item_assignees composite-key) and the signed-write path is proven by
  `LiveAuthWriteTests`. A signed `-simulateOffline` seed drill captures the
  offline banner + pending chips. **Recommended pre-launch:** one manual
  airplane-mode round-trip on a device (edit offline → reconnect → confirm
  reconcile + "edited by X") to exercise the full path end-to-end on real
  hardware.

**Dynamic Type: ✅ shipped.** Full support landed in the award-polish engagement
(2026-07-11): all ~53 icon sites now scale via `@ScaledMetric(relativeTo:
.body)` or `.system(size:)` recipes. Layout branches (`dynamicTypeSize
.isAccessibilitySize`) added to: flight boarding-pass header (vertical IATA/
route stacking), add-form category selector (horizontal scroll instead of
5-equal-width tiles), timeline card rows, home header, packing header, and
segmented control. Confirmation-code copy button and paste-import pill hit
targets raised to 44pt (AX5-ready). Verified live on simulator at
`accessibility5` (AX5) light and dark with screenshot evidence archived in
`.claude/company/handoffs/qa-evidence*/`. No clipping, no truncation, text
remains readable at all scales. Unit + UI test suite green (313 tests, 6 UI
tests). Not an App Review blocker; expected ship-ready.
