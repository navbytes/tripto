# Tripto email-import — go-live runbook

The one console sitting that turns the email-import pipeline on, plus how to
verify it and how to turn it back off. Consolidates
[`docs/EMAIL_IMPORT_PLAN.md`](../../docs/EMAIL_IMPORT_PLAN.md)'s "Go-live
gate" and [`docs/ROADMAP.md`](../../docs/ROADMAP.md) 1.2 into one runnable
checklist (ROADMAP 1.1). Companion script:
[`scripts/check-golive.sh`](scripts/check-golive.sh) — read-only, checks
every gate item below before and after the sitting. No secret **values**
appear anywhere in this document, only secret **names**.

## Status as of 2026-07-14 — read this before doing anything

This runbook was drafted assuming the pipeline was dark: that's what
`EMAIL_IMPORT_PLAN.md`'s "Go-live gate," `docs/BACKLOG.md` §A2, and
`docs/ROADMAP.md` Phase 1 all still say. **Running `check-golive.sh` while
writing this found otherwise** — every read-only check below reports live:
`plans.tripto.navbytes.io`'s MX already resolves to Cloudflare Email Routing,
the apex (`navbytes.io`) MX is still iCloud (correctly untouched), the
`tripto-email` Worker is deployed with `EMAIL_INGEST_SHARED_SECRET` already
set, and an unauthenticated probe of `ingest-email` returns `401` (deployed,
auth enforced). `docs/HANDOVER_2026-07-10.md` independently corroborates
this: it records the secret set identically on both sides, the Worker
deployed, the catch-all rule made Active, and a real forwarded email
producing a real suggested item — all dated **2026-07-11**.

**In other words: §2 below appears to already be done.** The three docs
above haven't caught up (`ROADMAP.md` 2.5 is the already-tracked slot for
correcting `BACKLOG.md` §A2's status — worth doing before anyone re-reads
those docs and assumes a from-scratch sitting is still needed). Don't redo
§2 on the strength of those docs alone: **run `check-golive.sh` first**, and
only do the steps it reports as ⏳.

What the script (and this doc) can't prove by themselves: whether the two
`EMAIL_INGEST_SHARED_SECRET` values actually *match* (secrets are
write-only — presence on both sides isn't proof of equality), and whether
the catch-all rule really targets this Worker (the `wrangler email routing`
commands are open-beta and this machine's OAuth token doesn't carry their
scope). §3's real forward-an-email test is what actually proves both;
`check-golive.sh --live-test` is a lighter automated proxy for the secret
half only.

---

## 1. Pre-flight checklist

- [ ] Run `bash web/email-worker/scripts/check-golive.sh` and read every
      line — it tells you exactly which steps in §2 (if any) are still
      outstanding, right now, rather than trusting any doc's stated status.
- [ ] Confirm the Cloudflare **dashboard** session is the account that owns
      the `navbytes.io` zone. (`wrangler whoami`, part of the script,
      confirms the CLI's identity — that's a separate session from the
      browser dashboard; check both.)
- [ ] Have a secret generator ready: `openssl rand -hex 32`. If you're
      rotating an existing value rather than setting it for the first time,
      generate a fresh one — don't reuse an old value.
- [ ] Have both consoles open: the Cloudflare dashboard (`navbytes.io` zone)
      and either the Supabase dashboard (project `qgtveaqukvbtyunupzhn`) or
      `supabase` CLI access to `~/repos/backend/projects/tripto`.
- [ ] Skim `EMAIL_IMPORT_PLAN.md`'s Decisions table once (addressing scheme,
      confidence gating, retention) and this Worker's own
      [`README.md`](README.md) "Failure modes" table, so a quiet failure
      during testing doesn't look like a mystery mid-sitting.
- [ ] Know the one hard constraint before touching anything: **`navbytes.io`'s
      apex MX is iCloud+ mail** (`tripto@navbytes.io`) and must never change.
      Every step below is scoped to the `plans.tripto.navbytes.io` subdomain
      only.

---

## 2. The owner console sitting (~30 min)

Each step below is check-then-act — safe to read through even if some are
already done. Confirm with `check-golive.sh` and skip whatever it already
reports ✅.

### Step 1 — Email Routing enabled for the zone

Cloudflare dashboard → `navbytes.io` zone → **Email → Email Routing**. If
it already shows "Active," skip to Step 2.

⚠️ **Do not** use a top-level "Enable" flow if it prompts to take over the
zone's MX records outright — that demands exclusive control of the apex,
which would break iCloud+ mail (`navbytes.io`'s Email Routing "Enable" flow
does exactly this: *"Existing non-Cloudflare MX records conflict with Email
Routing"* if you let it target the apex). Use Step 2's **Settings →
Subdomains** path instead — it never requires enabling the apex.

### Step 2 — Add the subdomain, scoped only to `plans.tripto.navbytes.io`

Cloudflare dashboard → `navbytes.io` zone → Email → Email Routing →
**Settings → Subdomains → Add subdomain** → enter `plans`. This
auto-generates MX + SPF DNS records scoped to `plans.tripto.navbytes.io`
only — it will not offer to touch `navbytes.io` itself.

- [ ] Before saving, confirm every generated record shows
      `plans.tripto.navbytes.io`, never bare `navbytes.io`.
- [ ] After saving, verify from a terminal:
  ```sh
  dig +short MX plans.tripto.navbytes.io   # expect *.mx.cloudflare.net hosts
  dig +short MX navbytes.io                # expect unchanged mx01/02.mail.icloud.com
  ```
  (`check-golive.sh` runs exactly these two lookups.)

### Step 3 — Catch-all routing rule → this Worker

Email Routing → **Routing rules → Catch-all address → Send to a Worker** →
`tripto-email` (this Worker's `wrangler.jsonc` `name`). A catch-all (not a
per-address rule) is required because trip import tokens are minted
dynamically — see `EMAIL_IMPORT_PLAN.md`'s addressing decision.

Note: nothing in this repo's tooling can read the catch-all rule's target
back to confirm it (`wrangler email routing rules get navbytes.io
catch-all` exists but is open-beta, and this machine's OAuth token lacks
the scope it needs) — confirm this one visually in the dashboard, or via
§3's real forward test.

### Step 4 — Shared secret, set identically on both sides

The step most likely to be gotten wrong — **the two values must match
exactly**.

1. Generate one value:
   ```sh
   openssl rand -hex 32
   ```
   Copy it somewhere you can paste from twice; don't retype it by hand.
2. Set it on the Supabase side (from `~/repos/backend/projects/tripto/`):
   ```sh
   supabase secrets set --project-ref qgtveaqukvbtyunupzhn "EMAIL_INGEST_SHARED_SECRET=<value>"
   ```
3. Set the **exact same value** here (from `web/email-worker/`):
   ```sh
   wrangler secret put EMAIL_INGEST_SHARED_SECRET
   ```
   (paste when prompted — this deploys the new value immediately, no
   separate `wrangler deploy` needed for a secret-only change.)

- [ ] Confirm presence (names only) on the Worker side:
      `wrangler secret list` from `web/email-worker`
      (`check-golive.sh` check 2 does this).
- [ ] Confirm presence on the Supabase side:
      `supabase secrets list --project-ref qgtveaqukvbtyunupzhn` from the
      backend repo (names only — neither side can show you the value back;
      see backend `RUNBOOK.md` "Viewing current secrets").
- Neither list proves the two values **match** — that's exactly what §3's
  live forward test (or `check-golive.sh --live-test`) is for.

### Step 5 — Load Unified Billing credits for AI Gateway

Cloudflare dashboard → **AI Gateway → Credits Available** → add credits.
This is what actually pays for the LLM calls `ingest-email` makes through
Cloudflare's Unified Billing (`EMAIL_IMPORT_PLAN.md`'s Decisions table) —
`CLOUDFLARE_API_TOKEN` / `CLOUDFLARE_ACCOUNT_ID` are already set as secrets
on `ingest-email` (backend repo); this step is purely the billing balance
behind them.

- [ ] No CLI/script check exists for this one — it's a dashboard-only
      balance. Confirm visually; a `0` balance surfaces later as
      `ai_gateway_error` in `ingest-email`'s logs (see backend `RUNBOOK.md`'s
      failure-mode table), not as a clean error at send time.

### Step 6 — Deploy the Worker

```sh
cd web/email-worker
npm install
wrangler deploy
```

Only needed if `check-golive.sh` check 2 reports the Worker not yet
deployed, or after a code change to `src/`. Re-running `wrangler deploy` on
an already-deployed, unchanged Worker is harmless — it's an idempotent
upload, not a toggle.

---

## 3. Post-live verification

- [ ] Run `bash web/email-worker/scripts/check-golive.sh` — every check
      should read ✅. Any ⏳ means one of Steps 1–6 above isn't fully done.
- [ ] Open a trip's Add-Item / Share screen in the app (EI-2) and reveal its
      real `t-<token>@plans.tripto.navbytes.io` import address (behind the
      AI-processing consent dialog, BACKLOG §A5).
- [ ] Forward (or send) a real booking confirmation email to that address.
- [ ] Within a minute or two, confirm a `'suggested'` item appears in that
      trip's review inbox (the amber banner on the Itinerary tab).
- [ ] Confirm or dismiss it through the normal review flow (`AddItemSheet`
      edit mode) to prove the full loop end to end, not just the parse.

Where to look if nothing shows up:

| Look here | Console path | What it tells you |
|---|---|---|
| Worker logs | `wrangler tail` from `web/email-worker` | Token extraction, MIME parse, and the result of the POST to `ingest-email`. Never logs the email body, Subject, From, token, or secret (this Worker's own README, "No PII/secrets in logs"). |
| Edge function logs | Supabase dashboard → project `qgtveaqukvbtyunupzhn` → Edge Functions → `ingest-email` → Logs | A `401` here means the shared secret mismatched (see §2 Step 4); anything else is a genuine parse/DB issue. |
| AI Gateway logs | Cloudflare dashboard → AI Gateway → the gateway `ingest-email` calls (`default`) → Logs | The actual LLM call: model used (`LLM_MODEL`, default per `EMAIL_IMPORT_PLAN.md`'s Decisions table), latency, whether a tool call round-tripped. |
| `email_imports` table | Supabase Studio → Table Editor → `email_imports` (or `supabase db execute`, see backend `RUNBOOK.md`) | Every attempt lands a row regardless of outcome (`status`: `received` → `parsed` / `low_confidence` / `rejected` / `failed`) — the definitive audit trail when the app UI shows nothing at all. |

- [ ] Once this passes, record the result in `docs/CHANGELOG.md` and flip
      `docs/BACKLOG.md` §A2 to ✅ (`docs/ROADMAP.md` 1.3) — both outside
      this runbook's file scope, but the natural next step.

`check-golive.sh --live-test` is a lighter, non-visual alternative to the
forward-an-email test above: it sends one authenticated POST straight to
`ingest-email` to prove the shared secret matches, without needing a real
trip or a real email client. It deliberately cannot replace this section —
see the script's own `--help` and its printed warning for exactly what it
does and does not create.

---

## 4. Rollback — instant off switch

Turning the pipeline back off is **one step**, fully reversible, and
nothing else needs unwinding:

> Cloudflare dashboard → `navbytes.io` zone → Email → Email Routing →
> Routing rules → **disable (or delete) the catch-all rule** pointed at
> `tripto-email`.

That alone stops every inbound message from reaching the Worker. Everything
else is inert and safe to leave exactly as it is:

- **MX/SPF records on `plans.tripto.navbytes.io`** — harmless with no
  catch-all rule behind them; mail simply isn't routed anywhere. Remove them
  too (Settings → Subdomains) only if fully decommissioning the subdomain.
- **The deployed Worker and its secret** — a Worker with no route or
  catch-all rule pointing at it never runs.
- **`EMAIL_INGEST_SHARED_SECRET` on the Supabase side** — inert without
  inbound traffic reaching `ingest-email`.
- **AI Gateway credits** — a prepaid balance, not a subscription; no ongoing
  charge without live calls.
- **The apex (`navbytes.io`) MX** — never touched by any of this, in either
  direction; nothing to roll back there.

To go live again later: re-enable the catch-all rule. Everything else is
already in place.

---

Companion docs: [`docs/EMAIL_IMPORT_PLAN.md`](../../docs/EMAIL_IMPORT_PLAN.md)
(feature source of truth), [`README.md`](README.md) (this Worker's own
"Owner setup" walkthrough — this runbook supersedes it as the one-stop
procedure; `README.md` should eventually just point here, flagged but not
changed as part of this task), [`docs/ROADMAP.md`](../../docs/ROADMAP.md)
Phase 1, and `~/repos/backend/projects/tripto/RUNBOOK.md` (secret rotation
once live).
