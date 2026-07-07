# Research brief — pressure-test the Tripto build plan

**For:** a research session (AI or human) validating [BUILD_PLAN.md](BUILD_PLAN.md) before implementation starts.
**Output:** write findings to `docs/RESEARCH_FINDINGS.md` (format at the bottom). Do not modify BUILD_PLAN.md.

## Context (already decided — challenge with evidence, don't re-litigate from taste)

- Tripto: mobile-first trip organizer for families/groups; v1 = "best manual
  trip organizer" (BUILD_PLAN §2). Native **SwiftUI** app, iPhone first (§3.1).
- Backend already exists: a **Supabase** project (Postgres 17, ref
  `qgtveaqukvbtyunupzhn`), schema managed in the separate `navbytes/backend`
  repo. This is §3.2 "Path A" — treat it as chosen unless research uncovers a
  disqualifying gap.
- Research everything with **current (2025–2026) sources**; the mobile/BaaS
  ecosystem moves fast. Cite every load-bearing claim. Where sources conflict,
  say so. Distinguish verified facts from vendor marketing.

## Area 1 — Technical feasibility (highest priority)

The plan's riskiest assumption is **§7.1 offline & sync**: it assumes "BaaS
with realtime handles much of" offline read + optimistic edits. Supabase has
no built-in offline sync for Swift. Investigate:

1. **supabase-swift SDK maturity**: current version, auth (incl. **Sign in
   with Apple**, §3.5), realtime subscriptions, known gaps/issues on iOS.
   GitHub issues and recent release notes, not just docs.
2. **Offline/local-first options for Supabase + Swift**: what actually exists
   (e.g. PowerSync, ElectricSQL-style layers, hand-rolled SQLite/SwiftData
   mirror + reconcile)? Maturity, cost, and effort for each. What would
   field-level last-write-wins (§9.5) realistically require?
3. **The no-app share link** (§5.2): the read-only web view needs hosting.
   Evaluate serving it via Supabase Edge Functions vs. a static host reading
   through RLS-scoped access vs. a tiny Cloudflare/Vercel page. Effort + cost.
4. **Design details worth a sanity check**: Fraunces + Sofia Sans licensing/
   availability on iOS (§6.2); SwiftUI multiplatform (iPad/Mac) real-world
   effort for a v1 team of ~1.

## Area 2 — Competitive / market

5. Current landscape: TripIt, Wanderlog, and the 2025–2026 AI trip planners.
   For the top 3–5: what they do for **group/family coordination**, pricing,
   platform coverage.
6. **Review mining**: App Store/Play reviews and Reddit — what do users of
   these apps complain about regarding *group trips, shared itineraries,
   non-app family members*? Does the wedge (§1) actually exist?
7. Is a **view-only web link without an account** already table stakes in any
   competitor? (This is the plan's claimed v1 differentiator, §5.2.)

## Area 3 — v1.5 moat affordability

8. **Email-forwarding itinerary parsing**: build-vs-buy in 2026. Any usable
   parsing APIs/services? What did it historically take (TripIt's parser,
   WorldMate, etc.)? Realistic effort for "top 10–15 providers" (§2 v1.5).
9. **Flight-status APIs**: compare 2–3 aggregators (e.g. FlightAware
   AeroAPI, Cirium, AeroDataBox) on price at hobby scale, coverage, and terms.
   Concrete $ figures for, say, 50 tracked flights/month.

## Area 4 — Adversarial review of the plan itself

10. Go through BUILD_PLAN.md section by section and challenge it: internal
    contradictions, missing pieces (e.g. §8 M0 prescribes an OpenAPI contract
    — does that fit a Supabase/PostgREST backend, or should the contract be
    the SQL schema + generated types?), scope creep risks in v1, and the §9
    open questions — recommend an answer for each with reasoning.

## Output format (`docs/RESEARCH_FINDINGS.md`)

- **Executive summary** — the 5–10 findings that should change decisions.
- **Per-assumption verdicts**: for each numbered item above:
  `CONFIRMED / CHALLENGED / REFUTED` + evidence (cited) + what to change in
  BUILD_PLAN.md (name the section).
- **Recommended plan amendments** — a concrete, ordered list.
- **Open risks** — what couldn't be verified and how to de-risk it (spike,
  prototype, ask a human).
