# Tripto — testing runbook

How to run the test suites, and the one non-obvious prerequisite: **the UI
tests require anonymous sign-in to be enabled on the Supabase backend.**

## Test suites

- **Unit tests** (`TriptoTests`, 509 as of 2026-07-12) — hermetic: in-memory SwiftData, no
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
  `-uitestAutoSignIn`, which calls the **real**
  `Supa.client.auth.signInAnonymously()` against the backend to reach a
  signed-in state. **They only pass while anonymous sign-in is enabled on the
  backend** (see below). Run with `-only-testing:TriptoUITests`.
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

**CI tests:** Xcode Cloud's Test action uses the `Tripto-CI` scheme — unit
tests only, Required to Pass. (Cloud can't scope a Test action to targets, and
the UI tests need the anon-sign-in toggle, so they stay out of the CI scheme.)

## The anonymous-sign-in prerequisite — read before UI testing

**Decision (2026-07-11):** keep anonymous sign-in **enabled during
development/testing** and **disable it at launch**. Rationale: v1 exposes no
anonymous feature, the anonymous code is `#if DEBUG`-only (compiled out of
Release), so the only reason to disable it is trimming production attack
surface — which only matters once real users can reach the backend. It's a
**reversible backend toggle**, not a code change.

- **Before running the UI suite:** make sure anonymous sign-in is **ON**.
- **At launch / when done testing:** turn it **OFF** (the final pre-launch step
  in `RELEASE_READINESS.md` §2). Toggle it back on for any later UI-test run.

### How to toggle

The setting lives in the backend repo at
`~/repos/backend/projects/tripto/supabase/config.toml`:
```
[auth]
enable_anonymous_sign_ins = true   # true = testing, false = launch
```
Apply it:
```
cd ~/repos/backend/projects/tripto && supabase config push
```
Quick one-off alternative (no repo change): Supabase dashboard → project
`qgtveaqukvbtyunupzhn` → Authentication → **Allow anonymous sign-ins**. If you
toggle in the dashboard, mirror it in `config.toml` so the repo stays the
source of truth.

### Symptom if you forget

The UI tests fail as **"trip/element never appeared" timeouts**, not as visible
auth errors — the app just never leaves the welcome screen because the
anonymous sign-in call is rejected. If a UI run fails that way, **check this
toggle first.**

## The durable fix (if toggling becomes a chore)

The tidy long-term option is to stop the UI tests depending on the backend at
all: in the `#if DEBUG` `-uitestAutoSignIn` path, inject a **fake authenticated
session** instead of calling `signInAnonymously()`. Then the UI tests are
hermetic, production can keep anonymous sign-in off permanently, and the
occasional seed/auth-race flakiness (a UI run that lands on an empty home and
has to retry) goes away too. Not done yet — recorded here as the upgrade path.
Deferred rationale is in [`BACKLOG.md`](BACKLOG.md).
