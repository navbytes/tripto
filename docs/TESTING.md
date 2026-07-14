# Tripto — testing runbook

How to run the test suites. Both `TriptoTests` and `TriptoUITests` are fully
hermetic: no network calls, no backend settings to toggle (see "The
anonymous-sign-in prerequisite" below for the now-resolved history).

## Test suites

- **Unit tests** (`TriptoTests`, 611 as of 2026-07-14) — hermetic: in-memory SwiftData, no
  network, no auth. Always pass regardless of backend config. Run in Xcode
  (⌘U, TriptoTests) or:
  ```
  ./scripts/bootstrap.sh   # regenerate the project first — the .xcodeproj is
                           # gitignored (absent in a fresh clone), and a stale
                           # one silently misses newly added files
  xcodebuild test -project Tripto.xcodeproj -scheme Tripto \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:TriptoTests
  ```
- **UI tests** (`TriptoUITests`, 6) — drive the real app. Each launches with
  `-uitestAutoSignIn`, which (since 2026-07-14) injects a fixed synthetic
  session in `AuthManager.init` (`#if DEBUG`) — no network, no backend
  settings involved. Run with `-only-testing:TriptoUITests`.
- **Real Sign in with Apple** — a separate auth path, unaffected by the
  anonymous toggle; needs the App ID / SiwA console setup (see
  [`RELEASE_READINESS.md`](RELEASE_READINESS.md)).

(If you run these from the command line while Xcode is open on the project, add
your own `-derivedDataPath /tmp/dd-xyz` — Xcode holds a lock on the shared
DerivedData and concurrent CLI builds corrupt each other.)

**Lint:** CI enforces `swiftlint --strict` (installed and run by
`ci_scripts/ci_post_clone.sh`); the local build runs a non-strict SwiftLint
phase only if `swiftlint` is installed. Run `swiftlint --strict` from the repo
root before pushing to catch violations early. Same convention as SpotHK.

**CI tests:** every push to main auto-triggers the Xcode Cloud "CI" workflow —
a Test-only run of the `Tripto-CI` scheme (unit tests, Required to Pass; Cloud
can't scope a Test action to targets, so the scheme decides). The UI tests
were historically excluded because they needed the backend anon-sign-in
toggle; they're hermetic now, so adding them to the CI scheme is possible —
an owner call, since 6 simulator UI tests cost real Cloud compute minutes.
The "Default" workflow (manual + `v*` tags) additionally runs Test + Archive
for releases.

## The anonymous-sign-in prerequisite (resolved 2026-07-14)

**No longer applies — kept here for history.** `TriptoUITests` used to call
the real `Supa.client.auth.signInAnonymously()` via `-uitestAutoSignIn`, so
every run required toggling anonymous sign-in on in the backend first (and
off again before launch) — a production auth setting, tolerable pre-launch
but not a sane recurring workflow. That coupling is gone: `-uitestAutoSignIn`
now injects a fixed fake session directly in `AuthManager.init` (`#if
DEBUG`), so the suite never touches the network or the backend's auth
settings at all. See "The durable fix" below.

## Seeding real-shaped data via archive import

**Sanctioned way to load realistic trips for manual testing:** Settings → "Import trips" → select a Tripto Archive v1 JSON (`docs/IMPORT_FORMAT.md`). Conversion is deterministic and on-device (no AI, no consent dialog); imported rows then sync through the normal outbox like any other edit, so use a signed build when you want them to reach the backend. Re-import is idempotent. See the format spec's appendix for an LLM prompt to convert exports from other apps.

`DemoSeeder` remains the DEBUG-menu "Seed demo trip" fixture for lightweight deterministic testing. Archive import is for seeding a realistic multi-trip landscape before E2E flows.

## The durable fix — done (2026-07-14, BACKLOG.md C4)

`TriptoUITests` are now hermetic: in the `#if DEBUG` `-uitestAutoSignIn`
path, `AuthManager.init` installs a fixed, fully-synthetic `Session`/`User`
(deterministic UUID, far-future expiry, no `Date()`-dependent fields) and
skips subscribing to `authStateChanges` entirely, instead of calling the
real `signInAnonymously()` (now deleted). Production keeps anonymous
sign-in off permanently, the suite makes zero live network calls, and the
old seed/auth-race flakiness — plus the Keychain-persisted-session
`-uitestSignOut` pre-launch workaround it required — is gone with it.

One known (harmless) limitation: in `-uitestAutoSignIn` mode, signing out
in-app won't return to WelcomeView — the synthetic session has no
`authStateChanges` subscriber to clear it. No test combines the two flows;
if one ever needs to, clear the session directly in the DEBUG seam.
