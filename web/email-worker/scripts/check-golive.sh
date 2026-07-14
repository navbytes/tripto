#!/usr/bin/env bash
# check-golive.sh -- read-only gate checks for the email-import pipeline
# go-live (docs/EMAIL_IMPORT_PLAN.md "Go-live gate", docs/ROADMAP.md 1.1).
# Companion to ../RUNBOOK.md, which this script implements the "verify"
# half of -- run it before AND after the owner's console sitting.
#
# Every check here is read-only / additive: `wrangler whoami`, `wrangler
# secret list` (names only, never values), `dig` (public DNS lookups), and
# one unauthenticated `curl` (expected to be rejected). Nothing here
# deploys, writes a secret, changes DNS, or authenticates as anyone. The
# one exception -- an authenticated POST to the live ingest-email function
# -- only runs behind the explicit --live-test flag (see run_live_test()).
#
# Exit code: 0 unless a hard misconfiguration (an unambiguously wrong live
# state, e.g. the apex MX hijacked, or ingest-email accepting unauthenticated
# requests) is found -- a step that's simply not done yet (pre-live) is
# reported as pending, never as a failure.
set -uo pipefail

SUBDOMAIN="plans.tripto.navbytes.io"
APEX="navbytes.io"
INGEST_URL="https://qgtveaqukvbtyunupzhn.supabase.co/functions/v1/ingest-email"
SECRET_NAME="EMAIL_INGEST_SHARED_SECRET"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

HARD_FAIL=0
LIVE_TEST=0

# ---- output helpers: one line per gate item, per RUNBOOK.md's contract ----
pass()    { printf '  \xe2\x9c\x85 %s\n' "$1"; }                      # ✅
pending() { printf '  \xe2\x8f\xb3 %s\n' "$1"; }                      # ⏳
fail()    { printf '  \xe2\x9d\x8c %s\n' "$1"; HARD_FAIL=1; }         # ❌
section() { printf '\n%s\n' "$1"; }

usage() {
  cat <<'EOF'
Usage: check-golive.sh [--live-test] [--help]

Default: runs the read-only gate checks (wrangler auth, worker secret
presence, DNS MX for both the import subdomain and the apex, and an
unauthenticated probe of ingest-email). Safe to run anytime, in any state.

  --live-test   Also sends ONE authenticated POST to the live ingest-email
                function, to prove EMAIL_INGEST_SHARED_SECRET matches on
                both sides. Requires that secret in the environment (never
                as an argument). See the printed warning for exactly what
                this does and does not create. Off by default.
  -h, --help    Show this message.
EOF
}

for arg in "$@"; do
  case "$arg" in
    --live-test) LIVE_TEST=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "check-golive.sh: unknown argument '$arg'" >&2; usage; exit 1 ;;
  esac
done

# Resolve how to invoke wrangler once: prefer a global/PATH install (matches
# how this repo's own package.json scripts call it), fall back to npx
# --yes so a missing local install can't hang the script on an interactive
# prompt. Empty array = wrangler unavailable at all.
if command -v wrangler >/dev/null 2>&1; then
  WRANGLER_CMD=(wrangler)
elif command -v npx >/dev/null 2>&1; then
  WRANGLER_CMD=(npx --yes wrangler)
else
  WRANGLER_CMD=()
fi

# ── 1. Wrangler CLI ─────────────────────────────────────────────────────────
check_wrangler() {
  section "1. Wrangler CLI (read-only: wrangler whoami)"
  if [ ${#WRANGLER_CMD[@]} -eq 0 ]; then
    pending "wrangler not found and npx unavailable -- install Node.js + wrangler"
    return
  fi
  # Run from $WORKER_DIR (not wherever this script was invoked from) so
  # wrangler's own local cache lands there, not scattered at the caller's cwd.
  if (cd "$WORKER_DIR" && "${WRANGLER_CMD[@]}" whoami >/dev/null 2>&1); then
    pass "wrangler present and authenticated"
  else
    pending "wrangler present but not authenticated -- run: wrangler login"
  fi
}

# ── 2. Worker secret presence ────────────────────────────────────────────────
check_worker_secret() {
  section "2. Worker secret ($SECRET_NAME) -- wrangler secret list"
  if [ ${#WRANGLER_CMD[@]} -eq 0 ]; then
    pending "skipped -- wrangler unavailable (see check 1)"
    return
  fi

  local out
  if ! out=$(cd "$WORKER_DIR" && "${WRANGLER_CMD[@]}" secret list 2>&1); then
    if printf '%s' "$out" | grep -qi "not found"; then
      pending "Worker not deployed yet (wrangler secret list found no such Worker) -- expected pre-deploy"
    else
      pending "could not list Worker secrets -- ${out%%$'\n'*}"
    fi
    return
  fi

  if printf '%s' "$out" | grep -q "\"name\": *\"$SECRET_NAME\""; then
    pass "$SECRET_NAME is set on the Cloudflare Worker (name only -- values can't be read back)"
  else
    pending "$SECRET_NAME not set on the Worker yet -- wrangler secret put $SECRET_NAME (from $WORKER_DIR)"
  fi
}

# ── 3. DNS: import subdomain + apex (must never move) ───────────────────────
check_dns() {
  section "3. DNS -- MX records ($SUBDOMAIN and apex $APEX)"
  if ! command -v dig >/dev/null 2>&1; then
    pending "dig not found -- install bind-tools/dnsutils to run DNS checks"
    return
  fi

  # Canary lookup: if a domain entirely outside our control also comes back
  # empty, DNS resolution itself is the problem right now, not our records --
  # report that plainly instead of risking a false "misconfigured" verdict.
  if [ -z "$(dig +short +time=3 +tries=1 MX icloud.com 2>/dev/null)" ]; then
    pending "DNS resolution isn't answering right now (control lookup failed) -- skipping MX checks, retry later"
    return
  fi

  local sub_mx apex_mx
  sub_mx=$(dig +short +time=3 +tries=1 MX "$SUBDOMAIN" 2>/dev/null)
  apex_mx=$(dig +short +time=3 +tries=1 MX "$APEX" 2>/dev/null)

  if [ -z "$sub_mx" ]; then
    pending "$SUBDOMAIN has no MX yet -- pre-live (Email Routing not enabled / DNS not added)"
  elif printf '%s' "$sub_mx" | grep -qi 'mx\.cloudflare\.net'; then
    pass "$SUBDOMAIN MX points at Cloudflare Email Routing (live)"
  else
    fail "$SUBDOMAIN has an MX record that is neither empty nor Cloudflare's -- investigate: $sub_mx"
  fi

  # The apex is the safety-critical half of this check: it must ALWAYS stay
  # iCloud+ mail (tripto@navbytes.io). Never Cloudflare, in any state.
  if printf '%s' "$apex_mx" | grep -qi 'mx\.cloudflare\.net'; then
    fail "$APEX (apex) MX has been hijacked to Cloudflare -- must stay iCloud+ mail only, fix immediately"
  elif printf '%s' "$apex_mx" | grep -qi 'mail\.icloud\.com'; then
    pass "$APEX (apex) MX is unchanged -- still iCloud+ mail"
  else
    fail "$APEX (apex) MX is neither iCloud nor Cloudflare ($apex_mx) -- unexpected, verify manually"
  fi
}

# ── 4. ingest-email auth enforcement (unauthenticated probe) ────────────────
check_ingest_endpoint() {
  section "4. ingest-email endpoint (unauthenticated POST, expect 401/403)"
  if ! command -v curl >/dev/null 2>&1; then
    pending "curl not found -- cannot check the endpoint"
    return
  fi

  local code
  code=$(curl -s -o /dev/null -m 10 -w '%{http_code}' -X POST "$INGEST_URL" 2>/dev/null)
  case "$code" in
    401|403)
      pass "ingest-email is deployed and rejects unauthenticated requests (HTTP $code)"
      ;;
    000|"")
      pending "could not reach ingest-email (network/timeout) -- retry, or check Supabase project status"
      ;;
    2*)
      fail "ingest-email accepted an UNAUTHENTICATED request (HTTP $code) -- shared-secret check is not enforced"
      ;;
    *)
      pending "ingest-email returned HTTP $code (not 401/403, not 2xx) -- check Supabase function logs"
      ;;
  esac
}

# ── 5. --live-test: authenticated synthetic ingest (opt-in, creates a real
#      request against the live function) ──────────────────────────────────
run_live_test() {
  section "5. --live-test: authenticated synthetic ingest"
  cat <<'EOF'
  WARNING: this sends a REAL authenticated POST to the live ingest-email
  function, using the secret read from $EMAIL_INGEST_SHARED_SECRET (never
  pass it as an argument). By default the request uses a random token that
  matches no real trip -- ingest-email's own "unresolvable token" path (see
  its index.ts) writes NOTHING in that case, so this only proves the shared
  secret matches on both sides (expect HTTP 202). Set GOLIVE_TEST_TOKEN to a
  REAL trip's import token instead and this WILL create a real email_imports
  row (and possibly a real suggested item) on that real trip.
EOF

  if [ -z "${EMAIL_INGEST_SHARED_SECRET:-}" ]; then
    fail "--live-test requires EMAIL_INGEST_SHARED_SECRET in the environment -- export it and re-run"
    return
  fi
  if ! command -v curl >/dev/null 2>&1; then
    pending "curl not found -- cannot run --live-test"
    return
  fi

  local token="${GOLIVE_TEST_TOKEN:-}"
  if [ -z "$token" ]; then
    if command -v openssl >/dev/null 2>&1; then
      token=$(openssl rand -hex 16)
    else
      token="deadbeefdeadbeefdeadbeefdeadbeef"
    fi
  fi

  local code
  code=$(curl -s -o /dev/null -m 15 -w '%{http_code}' -X POST "$INGEST_URL" \
    -H "Content-Type: application/json" \
    -H "X-Ingest-Secret: $EMAIL_INGEST_SHARED_SECRET" \
    -d "{\"token\":\"$token\",\"from\":\"golive-check@example.com\",\"subject\":\"check-golive.sh live-test\",\"text\":\"automated check-golive.sh live-test, safe to ignore\",\"html\":null}" \
    2>/dev/null)

  case "$code" in
    200|202)
      pass "authenticated POST accepted (HTTP $code) -- EMAIL_INGEST_SHARED_SECRET matches on both sides"
      ;;
    401)
      fail "authenticated POST rejected (HTTP 401) -- EMAIL_INGEST_SHARED_SECRET does NOT match the Supabase side"
      ;;
    *)
      pending "unexpected HTTP $code from the live-test POST -- check Supabase function logs"
      ;;
  esac
}

main() {
  echo "Tripto email-import go-live gate -- $(date '+%Y-%m-%d %H:%M %Z')"
  echo "Read-only checks; see ../RUNBOOK.md for the console steps behind any ⏳/❌."

  check_wrangler
  check_worker_secret
  check_dns
  check_ingest_endpoint

  if [ "$LIVE_TEST" -eq 1 ]; then
    run_live_test
  else
    printf '\n(skipping the authenticated live-test -- pass --live-test to run it; --help for details)\n'
  fi

  echo
  if [ "$HARD_FAIL" -eq 1 ]; then
    echo "Result: hard misconfiguration found above (❌) -- fix before going further."
  else
    echo "Result: no hard misconfiguration found. Any ⏳ above is just a not-yet-done gate step -- see RUNBOOK.md."
  fi
  exit "$HARD_FAIL"
}

main "$@"
