# CLAUDE.md

Tripto — a mobile-first trip organizer for families/groups. **Native SwiftUI
Apple app** (iPhone first; iPad/Mac fast-follows).

**[docs/BUILD_PLAN.md](docs/BUILD_PLAN.md) is the source of truth** for scope,
architecture, data model, screens, and design system. Read §2 (scope) before
building anything; do not build v1.5/v2 features (email parsing, flight
status, expenses, maps tab) into v1. The `docs/*.jsx` files are interactive
React **mockups** — visual reference only, not app code; where they disagree
with BUILD_PLAN.md, the document wins.

## Backend — lives in a different repo

The backend is Supabase (BUILD_PLAN §3.2 "Path A"), and its schema is managed
in **`~/repos/backend`** ([navbytes/backend](https://github.com/navbytes/backend)) under `projects/tripto/`.
Read that repo's `CLAUDE.md` before backend work.

Hard rules in THIS repo:

1. **Never** run `supabase init`, create migration files, or apply DDL from
   here (no dashboard edits, no `execute_sql` writes). If a feature needs a
   schema change, make a migration in `~/repos/backend/projects/tripto/`
   (workflow documented there), or stop and tell the owner.
2. The **service-role key must never appear anywhere in this repo** — it
   bypasses RLS. The app uses only the publishable key below.

Project identity (public, safe to commit):

```
Project ref:  qgtveaqukvbtyunupzhn
API URL:      https://qgtveaqukvbtyunupzhn.supabase.co
Publishable:  sb_publishable_4x21OrhJWtnB1tDrhD9ueA_79p98yN-
```

## Security model the app must assume

- **Every table is RLS deny-by-default** (an event trigger in the backend
  auto-enables RLS on new tables). "Query returns no rows" usually means a
  missing/incorrect RLS policy in the backend repo, not an app bug.
- The three roles (organizer/companion/viewer, BUILD_PLAN §5.1) are enforced
  **server-side via RLS policies**. The app's role UI is convenience only —
  never treat client checks as the security boundary.
- The public share link (§5.2) returns a **sanitized** payload; never expose
  confirmation codes, notes, or emails through it.

## Client conventions

- Supabase access via the **supabase-swift** SDK; auth is **Sign in with
  Apple** through Supabase Auth (§3.5).
- Swift model types are defined in-app against the schema (§3.6 contract
  discipline). The backend repo generates TypeScript types
  (`shared/types/tripto.ts`) — use them as a **schema reference** when writing
  Swift models; they are not consumed directly.
- Store instants in UTC with the item's IANA tz alongside; display in the
  item's local time (§7.4). This is called out because it's where trip apps
  fail — follow the acceptance cases.
- Design tokens (§6.1–6.2) live once as data compiling to Swift constants;
  don't scatter raw hex through views.

## Working in this repo (build, test, gotchas)

- **Build system is XcodeGen.** `project.yml` is the source of truth;
  `Tripto.xcodeproj` is generated and gitignored. After adding/removing files
  or changing targets, run `scripts/bootstrap.sh` (`xcodegen generate`) — never
  hand-edit the `.xcodeproj`.
- **Test from the CLI** (or ⌘U in Xcode):
  ```
  xcodebuild test -project Tripto.xcodeproj -scheme Tripto \
    -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
    -only-testing:TriptoTests -derivedDataPath /tmp/dd-<name>
  ```
  `TriptoTests` are hermetic (in-memory, no network). `TriptoUITests` drive the
  real app.
- **Gotchas (each has cost real time):**
  - **Always pass your own `-derivedDataPath`** for CLI builds — Xcode locks the
    shared DerivedData and concurrent builds corrupt each other.
  - **Auth-write verification needs a SIGNED build.** supabase-swift keeps the
    session in the Keychain (absent when unsigned) → writes fall back to the
    anon key → `42501`. Looks like an RLS bug; isn't.
  - **`TriptoUITests` need backend anonymous sign-in enabled**
    (`-uitestAutoSignIn` → real `signInAnonymously()`); off at launch. See
    [docs/TESTING.md](docs/TESTING.md).
- **Quality bar — non-negotiable on new UI:** full Dynamic Type incl.
  accessibility sizes, VoiceOver labels, Reduce Motion, AA contrast, 44pt
  targets. One motion + haptic vocabulary in `Design/Motion.swift` — new
  animation uses it, no ad-hoc springs. Tokens in the generated
  `Design/Tokens.swift` + hand-written `PaletteExtras.swift`; no raw hex.

## Docs map

- [docs/BUILD_PLAN.md](docs/BUILD_PLAN.md) — **source of truth** (scope,
  architecture, data model, design system).
- [docs/RELEASE_READINESS.md](docs/RELEASE_READINESS.md) — App Store submission
  checklist (remaining actions are owner-only).
- [docs/TESTING.md](docs/TESTING.md) — running the suites + the anon-sign-in
  prerequisite.
- [docs/BACKLOG.md](docs/BACKLOG.md) — deferred work (email-import lifecycle,
  hardening).
- [docs/PRIVACY_DISCLOSURE.md](docs/PRIVACY_DISCLOSURE.md),
  [docs/CHANGELOG.md](docs/CHANGELOG.md).
