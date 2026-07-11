# Tripto — Release checklist

**Status: SUBMITTED to App Review 2026-07-12 — Build 4 (1.0 (4)), Waiting for
Review.** The app is built, tested, privacy-complete, and now in Apple's review
queue. What remains is the **manual release** (after the §2 backend cutover) once
review passes. Paste-ready metadata and privacy answers are at the end.

Last updated: 2026-07-12.

---

## 1. Build & sign — DONE (built via Xcode Cloud)

Built and signed in **Xcode Cloud** on Apple's released **Xcode 26.5 (17F42)**.
The build Mac runs a beta macOS whose local SDK is a pre-release seed that App
Review rejects (ITMS-90111) — reasoning + recipe in
[APP_STORE_SUBMISSION.md](APP_STORE_SUBMISSION.md) §0, §9–§10.

- [x] **Build with the Xcode 26 SDK** — Xcode Cloud, released Xcode 26.5.
  Deployment target stays iOS 17.
- [x] **App ID `io.navbytes.tripto`** — **Sign in with Apple** + **App Groups**
  (`group.io.navbytes.tripto`) enabled (SiwA verified on device 2026-07-11).
- [x] **Provisioning** — automatic signing generated the profiles; the signed
  archive (app + `io.navbytes.tripto.widgets` extension) succeeded, proving the
  App Group entitlement carried on both targets.
- [x] **Sign in with Apple key (.p8)** — Key ID `5YX6JK6K9A`, Team ID
  `59J9RQXYYP`. (`.p8` contents never committed.)
- [x] **`.p8` set as a Supabase secret** — the Apple token revoke fired on the
  device account-deletion test (§3), confirming it's live.

## 2. Pre-launch backend (before real users)

- [ ] **Disable anonymous sign-ins.** `enable_anonymous_sign_ins = true` is on
  only for DEBUG testing — turn it off (backend `config.toml` →
  `supabase config push`) before launch. Leaving it on now keeps the test flows
  working; flip it when you stop testing. The UI tests need it **on** —
  toggle procedure and why in [`TESTING.md`](TESTING.md).
- [ ] **Purge the anonymous test trips** accumulated in the DB.

## 3. Device checks (need a real device)

- [x] **Sign in with Apple** on a real device → lands on the trip list.
  _(verified on real device, 2026-07-11)_
- [x] **Delete a throwaway account** from Settings → signs out cleanly; the Apple
  token revoke fires (the `.p8` secret is set). _(verified on real device, 2026-07-11)_
- [ ] **Airplane-mode round-trip** (recommended, not a blocker) — edit offline,
  reconnect, confirm it reconciles and shows "edited by X".
- [ ] **TestFlight upgrade from Build 4** — install the next build directly
  over Build 4 on a real device (not a fresh install) and confirm existing
  trips/items survive the SwiftData lightweight migration (new `sourceRaw`
  attribute on `ItineraryItem`, added for on-device import). Recovery if
  ever needed: delete + reinstall — the local store is just a mirror, the
  backend re-syncs it.

## 4. App Store Connect — SUBMITTED (Waiting for Review)

**Submitted to App Review 2026-07-12, 1:21 AM — Build 4 (1.0 (4)), status Waiting
for Review.** Submission ID `5f53b010-8cb0-4d8c-b7ce-2fe48fb64c9b`.

- [x] Create the app: listing name **Tripto — Trip Organizer** (bare "Tripto"
  was taken; on-device name stays "Tripto"), bundle `io.navbytes.tripto`,
  primary language, **price Free**. _(created 2026-07-11)_
- [x] Metadata pasted (§6) + the six screenshots uploaded. _(2026-07-11)_
- [x] **App Privacy** filled (§5) — Name, Email, Other User Content, User ID; all
  App Functionality / linked / no tracking. _(2026-07-11)_
- [x] Age Rating **4+**, Categories (Travel / Productivity), Pricing (Free, all
  countries). _(2026-07-11)_
- [x] **Build attached + submitted:** Build 4 delivered via Xcode Cloud → App
  Store Connect (no local archive — see §1). Superseded Build 1, which was
  rejected **ITMS-90111** (seed SDK). _(2026-07-12)_
- [ ] **Manually release** once review passes — gated on the §2 backend cutover.

## 5. App Privacy answers (App Store Connect form)

Full detail in [`PRIVACY_DISCLOSURE.md`](PRIVACY_DISCLOSURE.md). Summary:

- **Tracking:** No. (No ads, no analytics SDKs, no device-location tracking.)
- **Data collected** (linked to account, purpose = app functionality):
  - Contact info — email + name from Sign in with Apple (may be an Apple
    private-relay address).
  - User content — trips, itinerary items (incl. confirmation codes and notes),
    packing lists, companion profiles.
- **Third parties have access: Yes** — the paste/email import sends booking text
  to an LLM provider (currently OpenAI) via Cloudflare AI Gateway to extract
  bookings. Import feature only; app functionality; not tracking. The app shows
  an explicit consent prompt before any text is sent (Apple Guideline 5.1.2(i)).

## 6. App Store Connect metadata (paste-ready)

- **Name (App Store listing):** Tripto — Trip Organizer  _(bare "Tripto" is
  taken; on-device name stays "Tripto")_
- **Subtitle (30 char):** Trips your whole group sees
- **Category:** Travel (primary); Productivity (secondary)
- **Age rating:** 4+
- **Price:** Free
- **Promotional text (170):** Turn scattered bookings into one shared, at-a-glance
  itinerary — built for families and groups, not just solo business trips.
- **Keywords (100):** trip,itinerary,travel planner,family trip,group travel,
  vacation,packing list,shared itinerary,flights,booking
- **Description:**
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
- **Support URL:** https://tripto.navbytes.io
- **Marketing URL:** https://tripto.navbytes.io
- **Privacy Policy URL:** https://tripto.navbytes.io/privacy
- **Copyright:** © 2026 navbytes
- **App Review notes:**
  > Sign in with Apple is the only sign-in method — no username/password and no
  > demo account are needed; please sign in with your own Apple ID.
  >
  > Quick tour: after signing in, tap "Plan a new trip"; open it and use the ＋
  > to add a flight/stay/activity; tap the share icon (top-right) for the
  > collaboration screen — you can generate an "anyone-can-view" link that opens
  > a read-only itinerary in any browser with NO app and NO account (booking
  > codes and notes are stripped), plus role-carrying invite links.
  >
  > Account deletion is in Settings (tap the avatar, top-right of Home) →
  > "Delete account"; it permanently deletes the account and revokes the Apple
  > token. The app works offline (reads + optimistic edits that sync on
  > reconnect). No third-party tracking or ads.
- **Demo account:** not required (Sign in with Apple).

---

## Already done (nothing needed — for confidence)

App built and hardened, **420 unit + 6 UI tests green**, all DEBUG/test surfaces
compiled out of Release. **Account deletion** built + verified end-to-end
(Guideline 5.1.1(v)). **Privacy policy published live** at
`tripto.navbytes.io/privacy` and linked in Settings. **AI-import consent
shipped** (Guideline 5.1.2(i)). Privacy manifest correct; shipping third-party
SDKs verified to need no manifest additions. Widgets + Live Activity + Siri
intents + Spotlight shipped; app icon (light + dark) + branded launch screen.
Sign in with Apple provider enabled + verified (GoTrue v2.192.0, clear of the
known issuer bug). Daily keep-alive cron live (no free-tier pause). Backend
privacy migrations applied to production; AI-gateway request logging disabled.

Deferred to their own features (not blockers): the email-import lifecycle and
its consent point, and other items in [`BACKLOG.md`](BACKLOG.md).

---

## 7. Regenerating the screenshots

The six 6.9" shots are captured from a **Debug build + DemoSeeder**, driven by
`-uitest*` launch args (no manual navigation), on an **iPhone 17 Pro Max**
simulator (1320×2868). `-screenshotMode` hides the Home debug menu; the seed is
deterministic and today-relative so the timeline's "Now" line lands in-trip.

```sh
# build once (own derivedDataPath — see CLAUDE.md gotcha)
xcodebuild -scheme Tripto -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' \
  -derivedDataPath /tmp/dd build
UDID=$(xcrun simctl create AppStore-6.9 "iPhone 17 Pro Max"); xcrun simctl boot $UDID
xcrun simctl status_bar $UDID override --time 9:41 --batteryState charged \
  --batteryLevel 100 --cellularBars 4 --wifiBars 3 --dataNetwork wifi
xcrun simctl install $UDID /tmp/dd/Build/Products/Debug-iphonesimulator/Tripto.app
BASE="-screenshotMode -uitestAutoSignIn -uitestSeedIfEmpty -uitestSeedToday"
# per screen: terminate, launch with the screen's arg(s), wait ~9s, screenshot
#   home       : (BASE only)
#   itinerary  : -uitestOpenFirstTrip
#   boarding   : -uitestOpenFirstTrip -uitestOpenBookingDetail
#   share      : -uitestOpenFirstTrip -uitestOpenShare
#   packing    : -uitestOpenFirstTrip -uitestOpenPacking
#   privacy    : -uitestOpenSettings, then tap the Privacy row (no deep-link)
```

First launch on a fresh sim can land on the springboard if the seed/auth race
loses — relaunch and it seeds. The full `-uitest*` catalog is in the source
(`grep -rhoE '"-uitest[A-Za-z]+"' Tripto/Sources`).
