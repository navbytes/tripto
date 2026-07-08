# Tripto — App Store release readiness

Living checklist to take Tripto from "feature-complete" to "submitted." Status
keys: ✅ done · 🔄 in progress · ⏳ queued (I can do it) · 🔑 **owner-only**
(needs your Apple account / credentials — I cannot do these autonomously).

Last updated: 2026-07-08.

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
500 on the Apple token path. We de-risk by (a) keeping the DEBUG anonymous/OTP
paths for development, (b) testing SiwA against *this* project the moment the
Apple App ID exists, (c) budgeting a support escalation if it 500s.

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
| M5 offline hardening + a11y + perf pass | ⏳ |

## 2. Submission apparatus

| Item | Status | Notes |
|---|---|---|
| App icon (1024, no alpha) | ✅ asset made | `Assets.xcassets/AppIcon`; wire `ASSETCATALOG_COMPILER_APPICON_NAME` in project.yml after M3b |
| Launch screen (branded) | ⏳ | replace blank `UILaunchScreen: {}` with a dusk wordmark screen |
| Privacy manifest `PrivacyInfo.xcprivacy` | ⏳ | declare UserDefaults required-reason (CA92.1); tracking = false. §4 |
| Hosted privacy policy | ⏳ | serve at `tripto.navbytes.io/privacy` (extend the Worker) |
| App Privacy "nutrition labels" | ⏳ draft | §4 — fillable copy ready for App Store Connect |
| Release-build hygiene (DEBUG gating) | ⏳ | audit anon sign-in / seeder / `-uitest` hooks are `#if DEBUG`; Release archive clean. §3 |
| Encryption compliance | ✅ | `ITSAppUsesNonExemptEncryption = false` (standard TLS only) |
| Permission usage strings | ◑ | Calendar ✅ (`NSCalendarsUsageDescription`); no location/photos/contacts prompts (MKLocalSearchCompleter needs none) |
| Account deletion (5.1.1(v)) | 🔄 | RPC + UI in M3b; **SiwA token revocation edge function** still owed (§5) |
| Sign in with Apple entitlement + provider | 🔑/⏳ | entitlement + Supabase Apple provider config; Apple-side is owner (§6) |
| Screenshots (6.7" + 6.9") | ⏳ | capture from finished screens after M4/M5 |
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
deletion. M3b ships the UI + `delete_account()` RPC (verified: removes the
auth user, cascades trips/memberships). **Additional obligation because we use
SiwA:** on account deletion the app must call Apple's token-revocation REST
endpoint. That needs an Apple private key (.p8) + key ID + team ID to mint a
client secret — server-side, so an **edge function** (`revoke-apple-token`) in
the backend repo, invoked by `delete_account`. Owner provides the key material
(§6); I build the function. Until then, data deletion (the core requirement) is
satisfied; token revocation is the remaining compliance gap and is flagged in
the Settings code.

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
   Apple** capability enabled.
3. **Sign in with Apple key**: create a Key (.p8) with SiwA enabled; note the
   **Key ID** and your **Team ID**. Send me the Key ID + Team ID (NOT the .p8
   contents in plaintext here — you'll add the .p8 as a Supabase secret / GitHub
   secret yourself). Needed for token revocation (§5) and the Supabase provider.
4. **Supabase Apple provider**: in the backend repo I'll set
   `[auth.external.apple] enabled = true, client_id = "io.navbytes.tripto"` and
   push it; you confirm it in the dashboard. (I can do the config push; you
   verify.)
5. **Associated domain** (optional, for universal links): add the Team ID to the
   Worker's `APPLE_TEAM_ID` var (I redeploy) and I'll add the
   `applinks:tripto.navbytes.io` entitlement + pin the signing team in
   project.yml. Custom-scheme `tripto://` invites work without this.
6. **App Store Connect record**: create the app (name "Tripto", bundle id,
   primary language), fill metadata (§7 — I draft it), upload screenshots
   (I generate), answer App Privacy (§4), set price = Free.
7. **Archive & upload**: with the signing team pinned, Product → Archive in
   Xcode (or `xcodebuild archive` + Transporter) → upload → submit for review.

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

## 8. Remaining risks (from research, carried here)

- SiwA-on-Supabase issuer 500 — test against this project once the App ID
  exists; DEBUG OTP fallback keeps dev unblocked.
- Free-tier pause kills live share links between trips — decide keep-alive vs Pro.
- Name proximity to TripIt/Tripoto — accepted at personal scale; low rejection
  risk, non-zero. (Owner decided to keep "Tripto".)
- iCloud+ mail has no inbound API — only matters for the v1.5 email-import
  feature, out of v1 scope.
