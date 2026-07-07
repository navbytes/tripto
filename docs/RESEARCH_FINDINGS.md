# Research findings — pressure-test of BUILD_PLAN.md

**Date:** 2026-07-08 · **Method:** multi-agent deep-research (5 search angles → source
fetch → claim extraction → 3-vote adversarial verification; 90 agent results, 133
extracted claims, 56 verification votes) plus direct primary-source checks (GitHub
API, registry RDAP/WHOIS, live pricing pages, Spamhaus/ICANN records) and a local
adversarial read of BUILD_PLAN.md against the repo, mockups, and the live backend
repo state. Verification notes: the research workflow stalled before its formal
synthesis stage; findings below were synthesized directly from its journaled,
already-verified claims. Votes killed one claim (a mis-framed "reconnect
regression"); it is excluded. Sources are cited inline; vendor-marketing claims are
flagged where they survived only as marketing.

---

## Executive summary — findings that should change decisions

1. **§7.1's core assumption is wrong: Supabase gives Swift apps zero offline.**
   The official SDK has no offline store or edit queue — the request sat open 2.5
   years and was stale-closed *not planned* in March 2026, with a Supabase team
   member pointing to third-party PowerSync instead. Offline must be architected
   in-app (local store + outbox) from M1, not "hardened" at M5.
2. **Email invites cannot ship as designed.** Supabase's built-in SMTP allows ~2
   auth emails/hour; Sign in with Apple routinely yields private-relay addresses
   that will never match a typed invite email; and the plan's pending-invite schema
   (`TripMember` PK containing a nullable `user_id`) is invalid Postgres. Replace
   with role-carrying **invite links** claimed via an RPC.
3. **The "no-app view link" is not a differentiator — it's table stakes.** TripIt
   ships a public no-account share URL with sanitization (confirmation numbers,
   costs, and documents hidden from viewers); Wanderlog has view-only links too.
   Tripto's real family differentiators are non-app **profiles** (assignable
   kids/grandparents) and the per-person lens — reframe §5.2 as parity-done-right.
4. **The wedge itself is real and evidenced.** Families literally run TripIt and
   Wanderlog *in parallel* to cover each other's gaps; Wanderlog's funded parser
   fails on real confirmations; TripIt's mobile UX is called dated by its own
   fans; a visible non-app segment (printed-Excel grandparents) exists.
5. **Sign in with Apple has a live operational failure mode on Supabase.** Apple
   migrated its OIDC issuer (appleid.apple.com → account.apple.com); Supabase Auth
   fixed validation in v2.177.0 (July 2025), but a March-2026 report shows hosted
   projects still failing with HTTP 500 eight months later, unanswered for four
   months. Test SiwA against *this* project in M1; keep a debug fallback.
6. **The free tier pauses — and that kills share links.** Supabase free projects
   pause after ~1 week idle (manual dashboard unpause). Between trips, the family's
   saved links and the app itself go dark. Decide: keep-alive ping, accept manual
   unpause, or $25/mo Pro once links are depended on. (PowerSync's free tier has
   the same 1-week deactivation.)
7. **Flight status at hobby scale is only affordable via AeroDataBox** (~$0–5.35/mo
   at 50 flights). FlightAware's free tier is personal/academic-use only —
   commercial use starts at a $100–200/mo minimum (sources conflict on the figure;
   both are 20–40× AeroDataBox). Cirium is enterprise/sales-gated.
8. **Email parsing in 2026 is buy-or-LLM, not hand-rolled templates.** A commercial
   parsing API exists (AwardWallet, sales-gated pricing, 40+ languages), and an
   indie competitor (tripwaffle, Jan 2026) ships generic email parsing solo with
   inference-cost economics. The "top 10–15 provider templates" plan (§2 v1.5) is
   the wrong shape — even 20-year incumbent TripIt still misparses.
9. **M0's OpenAPI contract doesn't fit the chosen backend.** With Supabase/
   PostgREST, the contract is the SQL schema + RLS matrix + generated types
   (the CLI generates **Swift** natively) + a short RPC list.
10. **Naming resolved by decision (2026-07-08):** the app stays **Tripto** at
    personal scale. tripto.app is squatted ($19,499 ask); a same-named app exists
    on Google Play; TripIt/Tripoto are 1–2 letters away. Product endpoints move to
    the owned domain: share links at **tripto.navbytes.io**, email import at
    **tripto@navbytes.io** (iCloud+ custom domain, MX verified live).

---

## Per-assumption verdicts

### Area 1 — Technical feasibility

#### 1. supabase-swift SDK maturity — **CONFIRMED (healthy), with one live caution**

Evidence (all verified against the GitHub API / release pages on 2026-07-07):
- Latest release **v2.50.0 (2026-07-06)**; 129 releases total; five releases in the
  three weeks before the check; ~1,259 stars, 253 forks, 3 open issues; MIT.
  Realtime, Auth, PostgREST, Storage, Functions are first-class modules; all Apple
  platforms supported (iPad/Mac fast-follow covered); SPM distribution.
- **Floor raised in v2.50.0: Swift 6.1+, Xcode 16.3+, iOS 16+ / macOS 13+.** Sets
  Tripto's deployment target (fine — we target iOS 17+).
- Realtime reliability is *functional but freshly patched*: a fatal RealtimeV2
  crash (#469) was fixed in 3 days back in 2024; **app background/foreground
  lifecycle handling only landed in v2.45.0 (April 2026)** — before that, apps
  hand-rolled reconnection (maintainer-confirmed gap, #595, open 17 months);
  a "deaf socket" fix shipped v2.47.2 (June 2026); silently-dropped REST
  broadcasts and a heartbeat retain-cycle fixed in v2.50.0 (July 2026).
- **Caution — Sign in with Apple:** open issue (March 2026, zero maintainer
  responses in ~4 months): native `signInWithIdToken` returning HTTP 500 on a
  hosted project because Supabase Auth validated against Apple's old OIDC issuer;
  the server-side fix (auth v2.177.0, July 2025) had not reached that project.
  The failure is specific to the Apple token path.

**Plan change:** pin SDK ≥ 2.50.0 (§3.5); add an M1 acceptance case "SiwA
round-trips against project qgtveaqukvbtyunupzhn"; keep a DEBUG-only email-OTP
fallback for simulator/dev.

#### 2. Offline/local-first options — **CHALLENGED; §7.1's premise REFUTED**

- "Path A BaaS with realtime handles much of this" (§7.1) is false for Swift:
  **issue #113 "Offline Support" (Oct 2023) closed as *not planned* by stale-bot
  on 2026-03-08** after 22 upvotes/10 comments and no maintainer commitment; a
  Supabase team member's answer was "use PowerSync."
- **PowerSync** (the only packaged option): official Swift SDK **1.14.4
  (2026-06-22)**, 38 releases, Apache-2.0, Supabase officially supported with demo
  connectors; iOS 15+ floor. Free tier **$0/mo: 2 GB synced/mo, 500 MB hosted, 50
  peak connections** (verified live on pricing page); next tier $49/mo. Caveats:
  free instances deactivate after 1 week idle; requires Postgres **logical
  replication** — on an idle Supabase project this has a documented WAL-growth
  failure mode (cap `max_wal_size`/`max_slot_wal_keep_size` ≈ 1 GB); write
  semantics (incl. any LWW) are still *your* code in the upload connector; GRDB
  integration is alpha.
- **Hand-rolled** (SQLite/SwiftData mirror + outbox): feasible — a repo
  contributor built exactly this and reports it works but is app-specific.
- **Field-level LWW (§9.5)** is not free anywhere: PowerSync provides no conflict
  strategy; hand-rolled needs per-field versions. Row-level LWW via `updated_at`
  + `updated_by` with a visible "edited by X" chip is the honest v1.

**Decision (autonomy granted):** hand-rolled local-first store (SwiftData mirror,
outbox with row-LWW reconcile) — zero extra services at personal scale, no
replication-slot ops risk on a pausing free-tier DB. PowerSync documented as the
upgrade path if scale/complexity grows. §7.1, §8 M1/M5 amended accordingly.

#### 3. Share-link hosting — **CONFIRMED cheap; design corrected**

- Sanitization **cannot be a plain RLS table read** (§3.4's "these become
  table/RLS operations" glosses this): stripping confirmation codes/notes/emails
  requires a `security definer` RPC (or view) — the web layer then just renders it.
- Owner already holds **navbytes.io on Cloudflare** (verified: NS + MX live), so a
  free **Cloudflare Worker on tripto.navbytes.io** (or a Supabase Edge Function as
  interim) server-renders the page: effort ≈ a day incl. AASA file for universal
  links; cost $0.
- Operational caveat: **free-tier pausing** (finding #6) silently kills the link
  between trips — a growth-loop/trust bug, not a hosting one.

#### 4. Fonts & multiplatform — **CONFIRMED (fonts); iPhone-first CONFIRMED (judgment)**

- **Fraunces:** SIL OFL 1.1 (verified on Google Fonts + in-repo OFL.txt;
  copyright 2018 The Fraunces Project Authors). Variable, 4 axes — opsz 9–144,
  wght 100–900, plus custom **SOFT/WONK axes that stock SwiftUI Font APIs don't
  expose** (use static instances or CTFontDescriptor). ~380 KB; actively
  maintained on GF (metadata 2025-09-10). The GitHub repo's last *release* is
  2020 — treat Google Fonts as the distribution channel.
- **Sofia Sans:** SIL OFL 1.1 (copyright 2019 The Sofia Sans Project Authors);
  variable wght 1–1000 + 24 static styles; Latin/Greek/Cyrillic (no CJK); active
  (GF metadata 2025-09-04). **Trap, flagged loudly: "Sofia Pro" is a different,
  paid Mostardesign font ($249+ family, separate app-embedding license tier) —
  do not confuse when sourcing files.**
- OFL obligations: ship the license text, don't sell the fonts standalone. Bundle
  both in-app; never load from CDN.
- Multiplatform: no strong external data surfaced; the plan's own iPhone-first
  recommendation (§9.2) stands on general size-class QA cost. Verdict is
  judgment, marked as such.

### Area 2 — Competitive / market

#### 5. Landscape — **CONFIRMED crowded; positioning holds with edits**

- **TripIt** (SAP): free tier includes the email-forwarding parser (its core
  feature) *and* sharing; **Pro $49/yr** gates real-time flight alerts, alternate
  flights, terminal/gate. Three-tier per-traveler permissions (view / edit /
  edit-and-traveling) — Tripto's role triad is not novel. iOS + Android + web;
  offline itinerary access included.
- **Wanderlog:** collaboration with per-collaborator view/edit, email-forwarding
  import, expense tracking; app + web. (Its collab help article rates ~28%
  helpful — weak signal the flow confuses users.)
- **AI planners (2025–26):** thin coverage in this pass (one indie datapoint:
  tripwaffle, Jan 2026, LLM-style email ingestion). Marked an open gap — but
  nothing surfaced that does *family coordination* well.

#### 6. Review mining / does the wedge exist — **CONFIRMED**

- A family-trip thread concludes by **running TripIt and Wanderlog in parallel**
  (logistics vs day-planning, split between spouses) — the coordination gap in
  one anecdote.
- **Wanderlog's parser failed a German hotel confirmation three times and imported
  only one passenger from a 4-person flight email** (TripIt parsed the same email
  correctly). TripIt itself "misparses or drops items… requiring manual
  verification" per 2026 reviews, 20 years in.
- TripIt Pro's flight alerts are *loved* (2 a.m. strike-cancellation alert before
  the airline knew; "beats Delta every time") — the v1.5 feature has proven
  willingness-to-pay ($49/yr).
- Non-app family members are a real segment: printed Excel pages, Word-doc
  itineraries; Wanderlog requires collaborators to create accounts to edit.
- TripIt's design is "dated" even to fans; its multi-city *group* coordination is
  an asked-for gap (G2 reviewer).

#### 7. View-only no-account link table stakes? — **REFUTED as differentiator**

TripIt's public share URL opens in a browser with no account and hides
confirmation numbers/costs/documents from viewers; Wanderlog ships view-only
links (which leak budget data — their sanitization is worse). §5.2 should claim
*better defaults + profiles*, not novelty. Keep the feature in v1 regardless —
its absence would be disqualifying.

### Area 3 — v1.5 moat affordability

#### 8. Email parsing build-vs-buy — **CHALLENGED → buy-or-LLM**

- **Buy:** AwardWallet sells a parsing REST API (travel apps/TMCs; forwarded-email
  *and* mailbox-scan modes; 40+ languages; "highest success rate" is unverified
  vendor marketing; **pricing sales-gated** — a material unknown for a solo dev).
- **History says templates are a tar pit:** TripIt still misparses after 20 years;
  Wanderlog fails on real-world emails (item 6).
- **2026 shift:** tripwaffle (solo dev, Jan 2026) ingests "any provider" via
  email forwarding, corroborated by a user for emails TripIt couldn't parse;
  its stated economics are per-use inference cost, not template maintenance.
- **Amend §2 v1.5:** replace "parser for top 10–15 providers" with an LLM
  extraction pipeline (forwarded email → structured ItineraryItem draft → user
  confirms in-app), with AwardWallet as the fallback if quality disappoints.
  Operational note: tripto@navbytes.io is iCloud+ mail — **no inbound API**; the
  pipeline needs IMAP polling (app-specific password) or a future move of MX to a
  programmatic receiver. v1.5 detail, decided then.

#### 9. Flight-status APIs — **CONFIRMED affordable, via exactly one vendor**

| Vendor | Hobby-scale reality (verified) |
|---|---|
| **AeroDataBox** | Free: 600 units/mo (marginal). **PRO ≈ $5.35/mo** (6,000 units; RapidAPI) or $5 (API.Market) — realistic floor. Units ≠ requests (endpoint tiers 1/2/6 units); 1 req/s rate cap; schedules to 365 days out. Coverage is best-effort: US 100% schedule / 86% live-status, FR 92%/79%, gate/terminal "sometimes." Marketplace-only sales (RapidAPI/API.Market) = continuity/terms risk. |
| **FlightAware AeroAPI** | Free "Personal" tier is **personal/academic use only** — unusable for a shipped app. Commercial floor: Standard tier **$100/mo minimum per one source, $200/mo per another (sources conflict — resolve at purchase time)**; per-query costs themselves are pennies; push alerts included from Standard. |
| **Cirium** | Enterprise, sales-gated; no public pricing. Out at this scale. |
| (Aviationstack, unrequested comparator) | Free 100 req/mo (1 req/min, personal license); $49.99/mo next. |

At ~50 flights/month with sparse, departure-window polling: **AeroDataBox
$0–5.35/mo.** Polling cadence, not flight count, dominates cost (a worked example
shows naive 5-minute polling of 500 flights ≈ $8.6k/mo on query-billed APIs).
**Amend §2 v1.5:** name AeroDataBox as the aggregator; design around scheduled
sparse polls, not continuous tracking.

### Area 4 — Adversarial review of BUILD_PLAN.md — **CHALLENGED (multiple defects)**

Schema defects (§3.3) — all must be fixed in the M0 migration:
1. `TripMember` PK `(trip_id, user_id)` with nullable `user_id` is **invalid
   Postgres**; pending email invites can't exist as specced → superseded by
   invite-link tokens (see amendment 3).
2. `ItemAssignee.user_id → TripMember.user_id` FKs a non-unique column **and**
   contradicts the plan's own TripProfile note → `trip_profiles` table;
   assignees/packing reference **profiles**.
3. `PackingItem.group` is a reserved SQL keyword → rename (`group_key`).
4. `ShareLink.slug` example "lisbon/a7f3" is ~65k guesses and contains `/` —
   violates §5.2/§7.5 → ≥96-bit random token, rotate/revoke.
5. §5.6's `status` column ('suggested'|'confirmed') missing from the schema block.
6. No `updated_at`/`updated_by` anywhere, though §7.1 demands LWW + attribution.
7. `User.email unique` collides with SiwA private-relay reality; identity is
   `auth.users` + a `profiles` mirror (standard Supabase pattern).
8. Multi-day stays have no timeline bucketing rule → check-in/out cards +
   "staying at" strip on intermediate days (drawn in mockups v2).

Contract & API (§3.4, §8 M0):
9. OpenAPI M0 artifact → **SQL migrations + RLS policy matrix + generated types
   (supabase CLI supports `--lang=swift`; connection quirk: use `--db-url`) + RPC
   list** (`claim_invite`, `get_public_trip`, `delete_account`). Resolves the
   BUILD_PLAN-vs-repo-CLAUDE.md contradiction on generated-vs-hand-written models.
10. `GET /public/:slug` and invite-claiming both need SECURITY DEFINER RPCs —
    neither is expressible as plain RLS reads/writes.

Missing requirements:
11. **Apple 5.1.1(v): in-app account deletion is mandatory** (since June 2022),
    including SiwA **token revocation via Apple's REST API** — needs a server
    secret, i.e., an edge function. Absent from plan; added to M3.
12. Apple Developer Program $99/yr and the share domain are real costs the
    "near-zero" posture must name (domain resolved: owned navbytes.io).
13. §4.3 "Places API" contradicts §3.5's no-metered-services rule →
    MKLocalSearchCompleter (free, on-device).
14. The **Bookings sub-tab is listed but never specced** → defined as the flat
    confirmations list (mockups v2), or dropped.
15. Dark-mode token variants demanded by §6.5 but never defined → define at M0.
16. Ship checklist absent: privacy policy URL, App Privacy labels, TestFlight
    beta, crash reporting (MetricKit is free) → added to M5.

§9 open questions — answers adopted:
1. Import nudge: **show** as honest v1.5 waitlist; measure taps.
2. **iPhone-first**; iPad/Mac after v1 retains.
3. **Path A** (already provisioned; RLS guard live).
4. Map/$ Split: **hide**; Bookings specced (above).
5. Conflicts: **row-level LWW + "edited by X"**; field-level rejected for v1.
6. `trip_type` stays (family/friends/solo); family defaults: packing ON,
   link-priming ON, money=tracking (v2).

---

## Recommended plan amendments (ordered)

1. **Rewrite §7.1** — offline is app-architecture, not BaaS config: SwiftData
   mirror + outbox + row-LWW, built into the repository layer from M1; M5 is
   hardening only. (PowerSync = documented upgrade path.)
2. **Rewrite §3.3** per defects 1–8 (trip_profiles, invites table with token,
   share token ≥96-bit, `status`, `updated_at/by`, profiles-mirror of auth).
3. **Replace email invites with role-carrying invite links** (§3.4, §5.1):
   `create_invite(trip_id, role)` → `tripto.navbytes.io/join/<token>` →
   SiwA → `claim_invite(token)`. Kills SMTP limits, relay-email mismatch, and
   the invalid pending-row schema in one move.
4. **Redefine M0 contract** as schema + RLS matrix + generated Swift types + RPC
   list + acceptance cases (tz, roles, bucketing, sanitization).
5. **Add account deletion** (5.1.1(v)) to M3: cascade delete RPC + SiwA token
   revocation edge function + Settings UI.
6. **§5.2 reframe:** share link = table-stakes parity with stricter sanitization;
   the differentiators are profiles + "Just mine" + family defaults.
7. **§2 v1.5:** email import = LLM extraction with confirm-before-save (or
   AwardWallet), not provider templates; flight status = AeroDataBox PRO
   (~$5/mo), sparse polling.
8. **Decide the pause policy before M3** (share links must not die between
   trips): keep-alive ping vs $25/mo Pro vs accepted manual unpause.
9. **Domains/name (decided):** Tripto; tripto.navbytes.io links;
   tripto@navbytes.io import address.
10. **§6:** define dark-token variants at M0; bundle fonts (OFL texts in repo);
    avoid "Sofia Pro" confusion; §4.3 → MKLocalSearchCompleter.

## Open risks & how to de-risk

- **SiwA-on-Supabase issuer failure** (HTTP 500 reports on hosted projects,
  slow rollout of the fix): *de-risk in M1 with a live round-trip test against
  this project; fallback = email OTP; escalate to Supabase support if it 500s.*
- **Free-tier pause** (Supabase ~7 idle days; PowerSync free tier likewise):
  *decide amendment 8; a scheduled ping is a 5-minute cron.*
- **AeroDataBox marketplace terms** (RapidAPI/API.Market govern commercial use;
  tier-to-endpoint unit mapping lives in separate docs): *read both before v1.5
  commit; verify the flight-status endpoint's unit tier.*
- **FlightAware Standard minimum conflict** ($100 vs $200/mo across sources):
  *only matters if AeroDataBox disappoints; confirm with sales then.*
- **AwardWallet pricing opacity:** *one sales email when v1.5 starts; until
  answered, treat LLM extraction as primary.*
- **AI-planner competitive coverage is thin** in this pass: *revisit before any
  public launch; irrelevant at personal scale.*
- **iCloud+ mail has no inbound API** for tripto@navbytes.io: *v1.5 needs IMAP
  polling or an MX move for the import pipeline; decide then.*
- **Workflow stall:** the research harness died before formal synthesis; this
  document synthesizes its verified claims directly. Two stalled verification
  votes were re-derived manually (PowerSync pricing, SDK floor) — no finding
  rests on an unverified claim.
