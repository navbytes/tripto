# App Store submission — playbook & hard-won gotchas

A reusable runbook for shipping **this** app again, and for seeding a **new**
app without re-hitting the same walls. Written from Tripto's first 1.0
submission (2026-07-11), which was a **command-line-only archive** because the
build Mac was on a **beta macOS**.

Tripto's real values are inline; swap the ones marked _(app-specific)_ for a new app.

| Thing | Tripto value |
|---|---|
| App bundle ID _(app-specific)_ | `io.navbytes.tripto` |
| Widget/extension bundle ID | `io.navbytes.tripto.widgets` |
| Apple Team ID | `59J9RQXYYP` |
| App Group | `group.io.navbytes.tripto` |
| ASC API key location | `~/.appstoreconnect/private_keys/AuthKey_<KeyID>.p8` |

---

## 0. If the build Mac is on a BETA macOS — the SDK trap

The single biggest, most expensive trap. **On a beta macOS you likely cannot
produce an App-Store-accepted build locally at all** — plan for **Xcode Cloud
(§9)** or waiting for the RC. Budget for this before you promise a ship date.

Why:
- Only the **matching beta Xcode** launches its GUI; the release Xcode GUI errors
  *"This version of Xcode isn't supported in this version of macOS."*
- **Every Xcode on the machine carries a PRE-RELEASE SDK.** The beta Xcode has
  the next beta SDK; and even the *"release"* Xcode, on a beta OS, ships a **seed**
  SDK — Tripto's Xcode 26.6 GM (`17F113`) carried a *seed* iOS 26.5 SDK
  (`23F81a`), not the shipping `23F84`. Check with:
  ```sh
  /usr/libexec/PlistBuddy -c "Print :DTSDKName" -c "Print :DTPlatformBuild" \
      "<archive>/Products/Applications/App.app/Info.plist"   # a lettered build like 23F81a = seed
  ```
- App Store **submission** requires the **shipping / RC** SDK. A binary built
  against a beta *or seed* SDK is rejected — `ITMS-90111` / `90534` "Unsupported
  SDK or Xcode version" (see §8). Both local Xcodes are therefore dead ends.

> ⚠️ **This doc used to claim the release-Xcode CLI works on beta macOS and
> produces an accepted binary. That was WRONG.** The CLI *runs*, but it archives
> against the seed SDK, and Apple rejects the result. Uploading succeeds; the
> *submission* is rejected minutes later by email.

**Realistic options on a beta-macOS Mac with no second Mac:**
1. **Xcode Cloud (§9)** — builds in Apple's cloud on a real *release* Xcode/SDK,
   sidestepping your local SDK entirely. **This is the path that worked.**
2. **Wait for the RC** of the Xcode matching your OS (your beta Mac already runs
   that Xcode); rebuild the moment the RC ships.

If the Mac is on **release** macOS none of this applies — use the Xcode GUI
(Product → Archive → Distribute) or the CLI (§2), and skip to §3.

---

## 1. Credentials — there are TWO different `AuthKey_*.p8` files

Both download as `AuthKey_<KeyID>.p8`; they are **not** interchangeable.

| Key | Made at | Purpose |
|---|---|---|
| **Sign in with Apple** key | developer.apple.com → Certificates, IDs & Profiles → **Keys** | login-token signing (Supabase auth, account-delete revoke). Tripto: `5YX6JK6K9A`, already a Supabase secret. |
| **App Store Connect API** key | App Store Connect → **Users and Access → Integrations** | **signing + uploading builds.** Has a **Key ID _and_ an Issuer ID.** |

For CLI submission you need the **App Store Connect API key** (Admin access, so
it can create the distribution cert + profiles). First time on a team, click
**Request Access** to enable the API. Then:
```sh
mkdir -p ~/.appstoreconnect/private_keys
mv ~/Downloads/AuthKey_*.p8 ~/.appstoreconnect/private_keys/   # xcodebuild + altool auto-discover here
chmod 600 ~/.appstoreconnect/private_keys/AuthKey_*.p8
```
Note the **Key ID** (the `<KeyID>` in the filename) and the **Issuer ID** (UUID
at the top of the Keys page). Both are non-secret identifiers; the `.p8` is the
secret — never commit it, never paste its contents anywhere.

---

## 2. The CLI archive → export → upload runbook

Set once:
```sh
KEYID=<your-asc-api-key-id>
ISSUER=<your-asc-api-issuer-id>
KEY=~/.appstoreconnect/private_keys/AuthKey_$KEYID.p8
OUT=/tmp/appstore                 # scratch; anywhere outside the repo
mkdir -p "$OUT"
```

**(a) De-risk first — unsigned Release *device* build.** Catches Release-only
compile issues before you spend the credential (Debug/simulator builds and
tests won't catch them):
```sh
xcodebuild archive -scheme <Scheme> -destination 'generic/platform=iOS' \
  -archivePath "$OUT/App-unsigned.xcarchive" -derivedDataPath "$OUT/dd" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO
```

**(b) Signed archive** (auto-creates dist cert, profiles, and registers
capabilities/App Groups via the API key — no GUI, no manual portal work):
```sh
xcodebuild archive -scheme <Scheme> -destination 'generic/platform=iOS' \
  -archivePath "$OUT/App.xcarchive" -derivedDataPath "$OUT/dd" \
  -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY" -authenticationKeyID "$KEYID" -authenticationKeyIssuerID "$ISSUER"
```
> The **archive** may come out *Development*-signed — that's fine; the export
> re-signs. Don't panic at `Authority=Apple Development` on the archive.

**(c) Export a Distribution-signed `.ipa`.** `exportOptions.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>59J9RQXYYP</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
```
```sh
xcodebuild -exportArchive -archivePath "$OUT/App.xcarchive" -exportPath "$OUT/export" \
  -exportOptionsPlist "$OUT/exportOptions.plist" -allowProvisioningUpdates \
  -authenticationKeyPath "$KEY" -authenticationKeyID "$KEYID" -authenticationKeyIssuerID "$ISSUER"
```

**(d) Verify the `.ipa` (not the archive) is really App-Store-signed** before uploading:
```sh
cd "$OUT" && rm -rf v && mkdir v && cd v && unzip -oq ../export/*.ipa
codesign -dvv Payload/*.app 2>&1 | grep -E "Authority=Apple Dist|TeamIdentifier"   # want: Apple Distribution
codesign -d --entitlements :- Payload/*.app 2>/dev/null | grep get-task-allow      # want: <false/>
```

**(e) Upload** (altool auto-finds the `.p8` in `~/.appstoreconnect/private_keys/`):
```sh
xcrun altool --upload-app -f "$OUT/export/App.ipa" -t ios --apiKey "$KEYID" --apiIssuer "$ISSUER"
```
Then the build processes ~15–30 min before it's attachable in App Store Connect.

---

## 3. Bundle-validation errors — every one below only appears at UPLOAD

None of these fail a dev run, `xcodebuild build`, the test suite, or the
simulator. They only surface when altool validates. Fix, re-archive, re-upload.

| Code | Message | Fix |
|---|---|---|
| **90474** | *No orientations were specified* | Add `UISupportedInterfaceOrientations` to the app Info.plist (portrait-only is fine for a portrait app). |
| **90474** | *…include all 4 orientations to support iPad multitasking* | The app is **iPad-capable** but you only declared portrait. If iPhone-only is intended → **§4 below** (device-family trap). If you truly want iPad → declare all four, or set `UIRequiresFullScreen`. |
| **90360** | *Missing CFBundleDisplayName in …​.appex* | Add `CFBundleDisplayName` to **every app-extension's** Info.plist (widgets included). |
| 90704 | *Missing marketing icon* | 1024×1024 icon in the asset catalog (light **and** dark if you ship a dark icon). |
| 90056 / ITMS-90717 | image contains alpha / rounded corners | App icons must be opaque, square, no alpha. |
| **409** (upload, not a code) | *bundle version … must be higher than … previously used* | A **duplicate build number**, not a validation failure. Bump `CURRENT_PROJECT_VERSION`. **XcodeGen gotcha:** it hardcodes `CFBundleVersion "1"` in the generated Info.plist, so a build-setting bump is a silent no-op — drive the plist key off the setting: `CFBundleVersion: "$(CURRENT_PROJECT_VERSION)"` in `project.yml` info.properties (the app **and** every extension). |

## 4. The XcodeGen device-family trap (why "iPhone-only" wasn't)

Setting `TARGETED_DEVICE_FAMILY: "1"` under **`settings.base`** (project level)
in `project.yml` is **not enough** — XcodeGen's per-target setting-preset
injects a default `"1,2"` at the **target** level, which **overrides the project
base.** The app ships iPad-capable, and Apple then demands all four orientations
(90474 above).

**Fix — set it on the TARGET, where it wins:**
```yaml
targets:
  <AppTarget>:
    settings:
      base:
        TARGETED_DEVICE_FAMILY: "1"   # iPhone-only; overrides XcodeGen's "1,2" preset
```
Verify after `xcodegen generate`:
```sh
xcodebuild -showBuildSettings -scheme <Scheme> -destination 'generic/platform=iOS' \
  | grep 'TARGETED_DEVICE_FAMILY ='       # want: = 1
# and in the built app:
/usr/libexec/PlistBuddy -c "Print :UIDeviceFamily" .../App.app/Info.plist   # want: just { 1 }
```

## 5. App Store Connect record must exist BEFORE the upload

- altool error *"Cannot determine the Apple ID from Bundle ID …"* = **there's no
  app record yet.** Create it in the ASC UI first (**Apps → ＋ → New App**); the
  App Store Connect API **cannot** create app listings.
- The App ID/bundle ID only appears in the New-App dropdown **after** it's
  registered — the first signed archive (§2b) registers it automatically.
- **The bare brand name is usually taken.** The *store listing* name must be
  globally unique → use **"Brand: Descriptor"** (e.g. `Tripto — Trip
  Organizer`). This is separate from the **on-device** name (`CFBundleDisplayName`
  / `PRODUCT_NAME`), which stays your bare brand and is unaffected.

## 6. Seeding a NEW app — what's app-specific vs. reusable

Reusable as-is: §0 (beta-macOS SDK trap), §1 (key types), §2 (runbook), §3–5
(build gotchas), §7 (the console field-by-field + answer keys), §8 (automation
technique), §9 (SDK-version rejections), §10 (Xcode Cloud). Change per app:
bundle IDs, scheme name, App Group, the ASC app record + metadata, screenshots.
Same Team ID / ASC API key if it's the same Apple account. Re-run §2a first — a
fresh app is most likely to have a Release-only compile issue.

**On a beta macOS, skip §2 entirely and go straight to §10 (Xcode Cloud)** — a
local archive can't carry a shippable SDK (§0), so it'll only earn you the §9
rejection.

## 7. Filling the App Store Connect listing (metadata, Age Rating, App Privacy, Pricing)

Once the build is uploaded (§2) and the app record exists (§5), the rest is
web-console. Working order: version metadata → App Information → Age Rating →
Pricing → attach build → App Privacy → **Publish** privacy → **Submit for
Review**. The last two are the owner's clicks (legal/binding).

**Version page** (`…/version/inflight`)
- Promotional Text (170) · Description (4000) · **Keywords (100 chars _incl.
  commas_ — no space after commas; don't repeat words already in the app
  name/subtitle, they're indexed separately)** · Support/Marketing URL ·
  Copyright (`© <year> <entity>`).
- **App Review Information:** for a **Sign in with Apple-only** app, **uncheck
  "Sign-in required"** (there's no username/password to hand over) and say so in
  Notes — reviewers use their own Apple ID. Contact needs a real name + **phone
  with `+` and country code** (required — the #1 thing that blocks Save) + email.
- **Version Release:** pick **Manually release** when a backend cutover must
  precede go-live (e.g. disabling anonymous sign-in); otherwise Automatically.
- **Screenshots:** the well may demand **6.5" (1242×2688)**, not 6.9". Resize:
  `sips -z 2688 1242 shot.png`. One set covers all sizes. Drag-drop only — the
  browser tools can't upload local files, so this stays an owner action.

**App Information:** Subtitle (30) · Primary/Secondary **Category** · **Content
Rights → No** (app shows only the user's own data, not third-party content).

**Age Rating** (7-step): for an organizer/utility with no objectionable content,
**every answer is None/No → 4+**. The Step-1 capability questions that need
thought:
- **User-Generated Content → No** for *private, invite-only* sharing. The
  definition is "**broad distribution**"; a private group / read-only share link
  isn't that. Marking Yes obligates in-app moderation/report/block.
- Unrestricted Web Access → No (opening links in Safari ≠ an in-app browser).
- Messaging & Chat / Social Media / Gambling / Advertising → No.

**Pricing & Availability:** Add Pricing → base US → **$0.00** → confirm (Free in
all countries) · App Availability → **All countries**.

**Build:** version page → Build → **Add Build** → pick the processed build.
No export-compliance prompt if `ITSAppUsesNonExemptEncryption=false` is baked in.

**App Privacy** (`…/privacy`): set the **Privacy Policy URL**, then **Get Started
→ Yes, we collect data →** pick data types → for each set Purpose / Linked /
Tracking. For a Sign-in-with-Apple account app that stores user content and runs
no analytics/ads:

| Data type | Purpose | Linked to user? | Tracking? |
|---|---|---|---|
| Contact Info → **Name**, **Email Address** | App Functionality | Yes | No |
| User Content → **Other User Content** | App Functionality | Yes | No |
| Identifiers → **User ID** | App Functionality | Yes | No |

- **Declare "User ID"** whenever you assign account IDs (most account apps do),
  even though name/email already identify the user.
- A third-party sub-processor (e.g. an LLM used for paste/email import) adds **no
  separate toggle** — it's covered by declaring the data *collected* (the intro
  reads "you _or your third-party partners_ collect").
- Everything else (Location, Health, Financial, Contacts, Browsing/Search,
  Usage, Diagnostics) → leave unchecked. Then **Publish** (owner).

Tripto's exact paste-ready values: [RELEASE_READINESS.md](RELEASE_READINESS.md)
§5–6 and [PRIVACY_DISCLOSURE.md](PRIVACY_DISCLOSURE.md).

## 8. Driving App Store Connect by browser automation (agent notes)

When an agent fills the console via the **claude-in-chrome** MCP:
- It drives **real Google Chrome**, not the Claude app's built-in browser — ASC
  must already be **signed in in Chrome**. The agent must not do the Apple ID
  login (credentials are off-limits).
- **Text fields:** `form_input` usually works, but React-controlled inputs
  sometimes silently revert to empty — fall back to `computer left_click` the
  field, then `type`.
- **Radios & checkboxes:** clicking by pixel coordinate frequently misses the
  small target. Reliable path: `find` the option, or `read_page {ref_id:
  <dialogRef>}` to get **all** of a step's radio refs at once, then `computer
  left_click {ref: …}`.
- **Selects:** `form_input` with the option value works for native `<select>`
  (category); the price picker is a custom button-dropdown — click to open, then
  click the value.
- ASC is a heavy React SPA — pages render **blank/slow** right after a
  navigation; wait 3–6 s or reload before concluding a page is broken.
- Once a repeated multi-screen flow's coordinates are confirmed (e.g. the
  App-Privacy per-data-type purpose→linked→tracking), **batch** the clicks.
- Never click **Publish** (App Privacy) or **Submit for Review** — hand those to
  the owner.

## 9. "Invalid Binary" / ITMS-90111 / 90534 — the SDK-version rejection

Different class from §3: these **pass upload** (the binary lands in ASC,
processes, attaches to the version) and are rejected **minutes later, by email**,
*after* you submit for review. The ASC Resolution Center may only say "Invalid
Binary" with no detail — **the actual ITMS code arrives in Apple's email to the
account holder.** Read that email; don't guess from the ASC status.

- **ITMS-90111** *"…unsupported SDK / built with a beta version of …"* and
  **ITMS-90534** *"…built with a beta/seed SDK"* both mean **the binary's SDK is
  not a shipping/RC SDK.** Apple only accepts builds made against the current
  *released* (or late-RC) iOS SDK.
- **Diagnose from the binary itself** — no re-upload needed:
  ```sh
  /usr/libexec/PlistBuddy -c "Print :DTSDKName"   -c "Print :DTPlatformBuild" \
                          -c "Print :DTXcodeBuild" -c "Print :DTSDKBuild" \
      "<archive>.xcarchive/Products/Applications/App.app/Info.plist"
  ```
  A **lettered** platform build (`23F81a`, `23F5079e`) is a **seed/beta**; the
  shipping build has no trailing letter (`23F84`). `DTSDKName` (`iphoneos26.5`)
  names the SDK — cross-check it against the *currently shipping* iOS on Apple's
  release pages.
- **On a beta macOS, every local SDK is pre-release (§0)** so this rejection is
  unavoidable locally until an RC ships. The fix is **Xcode Cloud (§10)**, which
  builds on Apple's *released* Xcode/SDK.

**Reading any rejection, generally:** the version shows "Rejected" with a
Resolution Center thread, but Apple's **email** to the account holder is the
fuller record (exact ITMS code, or the guideline number for a *content*
rejection). If Resolution Center is terse, check email. For a *binary* rejection
nothing in your metadata is wrong — **don't touch the listing**, fix the build
and re-attach.

## 10. Xcode Cloud — the escape hatch when you can't build a shippable SDK locally

When the build Mac can't produce an accepted binary (beta macOS §0, or no release
Xcode at all), Xcode Cloud builds in Apple's cloud on a **real released
Xcode/SDK** and delivers straight to ASC. Free tier covers one app. The gotchas
that cost a night, in order:

**Creating the first workflow needs the Xcode GUI once.** Only Xcode can create
it (Product → Xcode Cloud → Create Workflow) — on a beta macOS that's the *beta*
Xcode, and that's fine: Xcode Cloud ignores your local SDK; the **cloud** Xcode
version is what matters. Once it exists, the **ASC web** (`…/app/<id>/ci` →
Manage Workflows) can *edit* it — but can't create the first one.

**Set the cloud Xcode to a released one.** Workflow → Environment → **Xcode
Version** → a *release* (e.g. "Latest Release" = Xcode 26.5 / `17F42`), never a
beta. This is the entire point — it sidesteps your local seed SDK.

**The workflow must actually deliver — a default "Build" action only compiles.**
For a submittable build:
- Actions → **Archive** → Platform **iOS** → **Distribution Preparation = App
  Store Connect**. Delete the redundant Build action.
- Each run then uploads a build to ASC automatically — no altool step.

**If the project is generated (XcodeGen/Tuist), regenerate it in CI.** The repo
commits `project.yml` but gitignores `*.xcodeproj`, so Xcode Cloud clones a repo
with no project to build. Xcode Cloud auto-runs `ci_scripts/ci_post_clone.sh`
after the clone — regenerate there:
```sh
#!/bin/sh
set -e
brew install xcodegen
cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate
```

**SPM needs a committed `Package.resolved`.** Xcode Cloud disables automatic
package resolution and fails with *"a resolved file is required"* if none is
committed. For a *generated* project the resolved file normally lives *inside*
the gitignored `.xcodeproj`, so commit a pinned copy (`ci_scripts/Package.resolved`)
and have the post-clone hook drop it into the freshly generated project:
```sh
# …same ci_post_clone.sh, after xcodegen generate:
SWIFTPM_DIR="Tripto.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$SWIFTPM_DIR"
cp ci_scripts/Package.resolved "$SWIFTPM_DIR/Package.resolved"
```
Regenerate that pinned file whenever dependencies change — copy it back out of a
local `xcodegen generate`d project.

**Trigger & watch:** ASC → app → **Xcode Cloud** tab → **Start Build** → pick the
workflow → branch → Start. ~15–25 min. A green run with the Archive action lands
the build under the version's **Build** picker (§7) automatically — then submit.

---

_Last updated 2026-07-12 (Tripto 1.0 — first submission, ITMS-90111 SDK
rejection on a beta-macOS local archive, then re-built via Xcode Cloud on a
released SDK). Companion: [RELEASE_READINESS.md](RELEASE_READINESS.md) for the
Tripto-specific checklist + paste-ready metadata._
