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

## 0. If the build Mac is on a BETA macOS — read this first

This was the single biggest trap.

- **Symptom:** the **release** Xcode won't launch — *"This version of Xcode isn't
  supported in this version of macOS."* Only the **beta** Xcode GUI opens.
- **The trap:** App Store Connect **rejects any binary built with a beta Xcode.**
  So the beta GUI is a dead end, and the release GUI won't run. Looks stuck.
- **The escape:** the release Xcode's **command-line tools run fine on beta
  macOS.** `xcodebuild` doesn't do the GUI's OS-version check, and the binary
  carries the **release SDK** (accepted). So you archive from the CLI (§2). No
  downgrade, no waiting for the public release, no second Mac.
- **Watch out:** `xcode-select -p` (which Xcode the CLI uses) is **independent**
  of which Xcode a `.xcodeproj` opens in. Verify both:
  ```sh
  xcode-select -p                                   # CLI toolchain (want the RELEASE one)
  ps aux | grep -i "Xcode.*/MacOS/Xcode" | grep -v grep   # which GUI is actually running
  ```
  `open Foo.xcodeproj` may hand the project to the beta. If you must use the GUI,
  quit the beta first (they share a bundle ID, can't run both at once).

If the Mac is on **release** macOS, just use the Xcode GUI (Product → Archive →
Distribute) and skip to §3 for the validation gotchas.

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

Reusable as-is: §0 (beta-macOS CLI path), §1 (key types), §2 (runbook), §3–5
(the gotchas). Change per app: bundle IDs, scheme name, App Group, the ASC app
record + metadata, screenshots. Same Team ID / ASC API key if it's the same
Apple account. Re-run §2a first — a fresh app is most likely to have a
Release-only compile issue.

---

_Last updated 2026-07-11 (Tripto 1.0 first submission). Companion:
[RELEASE_READINESS.md](RELEASE_READINESS.md) for the Tripto-specific checklist +
paste-ready metadata._
