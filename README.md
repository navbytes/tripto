# Tripto

A mobile-first trip organizer that turns scattered bookings into one shared,
at-a-glance itinerary — built for families and groups. Native SwiftUI app,
iPhone first.

- **Build spec:** [docs/BUILD_PLAN.md](docs/BUILD_PLAN.md) — scope, architecture, data model,
  screens, design system. Start here.
- **Mockups:** `docs/TripApp.jsx` (core screens), `docs/TripAppFamily.jsx`
  (family screens) — interactive visual reference.
- **Backend:** Supabase, schema managed in
  [navbytes/backend](https://github.com/navbytes/backend) under `projects/tripto/`. No schema work in
  this repo.
- **Agents:** read [CLAUDE.md](CLAUDE.md) first.

## Building

**Prerequisites:**
- Xcode 26+ (iOS 17 deployment target)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) — `brew install xcodegen`

The `.xcodeproj` is generated, not committed — [`project.yml`](project.yml)
is the source of truth. After cloning:

```sh
xcodegen generate   # or: scripts/bootstrap.sh
open Tripto.xcodeproj
```

Then run the **Tripto** scheme on an iPhone simulator (⌘R).

Re-run `xcodegen generate` any time `project.yml` changes (new files under
`Tripto/Sources`/`Tripto/Resources` are picked up automatically on the next
generate; you don't need to add them to Xcode by hand).

**Design tokens:** [`design/tokens.json`](design/tokens.json) is the single
source for the palette/type/spacing system. It compiles to
`Tripto/Sources/Design/Tokens.swift` (committed, generated — don't hand-edit
it) via:

```sh
python3 scripts/gen_tokens.py
```

Run this after changing `tokens.json`, before rebuilding.
