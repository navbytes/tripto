# Acceptance cases

Concise, testable cases for the behaviors BUILD_PLAN.md flags as easy to get
wrong (§7.4 time zones, §5.1 roles, multi-day bucketing, §5.2/§7.5 share
sanitization, §7.1 offline). These are the bar M2/M3/M5 build against; write
automated tests against them where the milestone covers that surface.

Amendments from RESEARCH_FINDINGS.md (schema defects, invite-link redesign,
row-level LWW) are folded in below where they change the expected behavior
from BUILD_PLAN.md's original text — noted inline.

---

## (a) Time zones

BUILD_PLAN.md §7.4: store instants in UTC + the item's IANA tz; display each
item in **its own location's** local time; never let a zone crossing be
misread.

### Case A1 — zone-crossing flight renders correctly

Given an itinerary item:

| field | value |
|---|---|
| category | flight |
| from | JFK (New York) |
| to | LIS (Lisbon) |
| departs | 2026-05-14 08:20, `America/New_York` |
| arrives | 2026-05-14 20:15, `Europe/Lisbon` |

Stored as UTC + tz per §3.3 (`starts_at`/`ends_at` UTC, `tz` IANA string):

- `starts_at = 2026-05-14T12:20:00Z`, tz `America/New_York` (EDT, UTC-4 — US
  DST is in effect: second Sunday in March to first Sunday in November).
- `ends_at = 2026-05-14T19:15:00Z`, tz `Europe/Lisbon` (**WEST, UTC+1** — not
  UTC+2; Portugal uses Western European Time/Summer Time, unlike most of
  continental Europe on CET/CEST. This is the exact mistake this case exists
  to catch.).
- Round-trip check: 19:15 UTC − 12:20 UTC = 6h55m, a realistic JFK→LIS block
  time — if an implementation's UTC math produces a wildly different
  duration, the tz offset is wrong.

Then the timeline must show:

1. The departure gutter reads **"08:20"** labeled **EDT** (or an equivalent
   explicit zone label) — not a bare, unlabeled "08:20".
2. The arrival reads **"20:15"** labeled **WEST/Lisbon time** — explicitly,
   so a reader cannot misread it as "20:15 New York time" (which would
   imply a ~12-hour flight and is the failure mode §7.4 calls out by name).
3. A **tz-shift indicator** ("+6h" / "Lisbon time" chip, or equivalent)
   appears **between the arrival and the next item**, whatever the next
   item is (e.g., a same-evening hotel check-in) — signaling explicitly
   that everything from here on is in a new zone. It must appear even if
   the next item is later the same calendar day in the new zone.
4. Mixed-zone times are never rendered side by side without a label —
   there is no code path that prints a bare "HH:mm" without an
   accompanying zone cue when consecutive items differ in tz.

### Case A2 — add-item form labels the zone by airport, not device locale

When adding a flight and the user fills **From: JFK**, the departure
date/time field's label/helper text reflects `America/New_York` (not the
device's current locale/tz) — the zone is derived from the selected airport,
not assumed from wherever the phone happens to be. Filling **To: LIS**
does the same for the arrival field against `Europe/Lisbon`. (v1 uses plain
text location fields per §4.3, so this depends on whatever
airport/city-to-tz resolution the add flow implements — at minimum, a
manual tz picker defaulted intelligently is acceptable if full
airport-code lookup isn't built yet; silently defaulting every field to the
device's local zone is not.)

---

## (b) Roles matrix

Three roles (BUILD_PLAN.md §5.1), enforced **server-side** via RLS — the
app's role UI is convenience only (CLAUDE.md). Matrix below mirrors
RESEARCH_FINDINGS.md Area 4's corrected policy design, not BUILD_PLAN.md's
original API sketch verbatim: assignments reference **`trip_profiles`**
(not `TripMember` directly — defect #2), and invites are **role-carrying
links** claimed via `claim_invite(token)`, not raw email sends (defect #1 /
amendment #3), since Supabase SMTP can't carry v1's invite volume and
Sign-in-with-Apple private-relay emails won't match a typed invite address.

| Action | Organizer | Companion | Viewer |
|---|---|---|---|
| View trip (itinerary, packing, members) | yes | yes | yes |
| Use the "Just mine" person filter | yes | yes | yes |
| Create trip | yes (becomes organizer) | — | — |
| Edit trip meta (title, dates, cover gradient, `trip_type`) | yes | no | no |
| Delete trip | yes | no | no |
| Add itinerary item | yes | yes | no |
| Edit itinerary item **they created** | yes | yes | no |
| Edit itinerary item **created by someone else** | yes | no | no |
| Delete itinerary item they created | yes | yes | no |
| Delete itinerary item created by someone else | yes | no | no |
| Add / toggle / assign packing item | yes | yes | no |
| Assign an item or packing task to a `trip_profiles` row (incl. a non-app kid/grandparent profile) | yes | yes | no |
| Create a role-carrying invite link (`create_invite(trip_id, role)`) | yes | no | no |
| Claim an invite link (join the trip via `claim_invite(token)`) | n/a | via link | via link |
| Change a member's role | yes | no | no |
| Remove a member | yes | no | no |
| Create / rotate the public view-only share link | yes | no | no |
| Revoke the public share link | yes | no | no |
| Read the public share link's sanitized payload (no auth) | n/a — anyone with the link, including non-members | | |

Notes:
- "They created" = the item's `created_by` matches the caller's `user_id`.
  A Companion can never restructure another member's items — only their
  own (§5.1's "cannot restructure others' plans").
- Viewer is read-only everywhere except the public/private read paths —
  this is the default for kids and low-tech grandparents, and is exactly
  the shape a `trip_profiles` (non-`User`) participant has via the share
  link, without ever needing an account.
- All rows are enforced by RLS policies + `SECURITY DEFINER` RPCs in the
  backend repo, not by this app hiding buttons. A client bug that shows an
  edit button to a Viewer must still fail server-side.

---

## (c) Multi-day stay bucketing

BUILD_PLAN.md defect #8: multi-day stays need an explicit timeline
bucketing rule. Example: a hotel booked check-in 2026-05-14, 3 nights,
check-out 2026-05-17.

| Day | Date | Timeline rendering |
|---|---|---|
| Day 1 | Wed May 14 | Full **check-in card** — hotel name, address, confirmation, room, check-in time. This is the "arrival" moment and carries full detail. |
| Day 2 | Thu May 15 | A slim **"Staying at ⟨hotel name⟩"** strip — low visual weight, no repeated address/confirmation block. Present so the day isn't blank, but doesn't compete with that day's other items. |
| Day 3 | Fri May 16 | Same slim **"staying"** strip as Day 2. |
| Day 4 | Sat May 17 | A **check-out chip** — compact, states check-out time; not a full card. |

Acceptance:
- Exactly one full detail card exists for the stay (day 1) — it does not
  repeat on days 2–3.
- Days 2–3 each show the strip so the day-grouped timeline never silently
  omits an ongoing stay (a family scanning "what's happening Thursday"
  must see they're still at the hotel).
- Day 4's chip is visually distinct from a same-day new-item card (smaller,
  no rail node icon repetition) so it doesn't read as a second booking.
- The rule generalizes: an N-night stay produces 1 check-in card + (N−1)
  staying strips + 1 check-out chip, spanning N+1 calendar days.

---

## (d) Share sanitization

BUILD_PLAN.md §5.2/§7.5, tightened by RESEARCH_FINDINGS.md (the no-app link
is table stakes, not a differentiator — ship **stricter** sanitization than
TripIt/Wanderlog, not just parity). Served by a `SECURITY DEFINER` RPC
(`get_public_trip`), not a plain RLS table read (defect #10 — sanitization
logic can't live in a row-security policy).

Given a trip with itinerary items that have confirmation codes, free-text
notes, precise `location_lat`/`location_lng`, and members with real names
and emails, when the public slug is fetched (`GET /public/:slug`, no auth):

- The payload contains item **titles, categories, times (with tz), and
  `location_name`** — enough to answer "where do we need to be."
- The payload contains **NO** `confirmation` values, for any item, ever.
- The payload contains **NO** `notes` text, for any item, ever.
- The payload contains **NO** `location_lat`/`location_lng` coordinates —
  only the human-readable `location_name`.
- The payload contains **NO** member identities — no emails, no real
  names of organizer/companions/viewers. (Item titles and location names
  may still be visible; *who is going* is not.)
- This holds even if the requester is one of the trip's own members
  browsing the public link logged out — the sanitized shape does not
  change based on who's asking, only whether the slug is valid.

Given a `ShareLink` that has been revoked (or rotated — the old slug no
longer matches any active link):

- The request returns an explicit error state (e.g. 404/410), rendered as
  a clear "this link is no longer available" message.
- It does **not** fall back to cached/stale data, and does not 500.

---

## (e) Offline drill

BUILD_PLAN.md §7.1, redesigned per RESEARCH_FINDINGS.md (Supabase's Swift
SDK ships no offline store — this is app architecture from M1: a local
mirror + outbox, not a BaaS feature to "harden" at M5). See
`docs/SYNC_DESIGN.md` for the implementing design (SwiftData mirror,
`OutboxOp`, the `SyncEngine` actor) — this is the acceptance bar it's
built against.

1. **Setup:** device has previously synced a trip (itinerary, packing list,
   members all loaded at least once).
2. **Go offline:** enable airplane mode.
3. **Read:** the full trip — every day's items, the packing list, the
   member list — remains readable from the local store. No blank states,
   no infinite spinners, no silent gaps versus what was last synced.
4. **Edit offline:** change a field on an itinerary item (e.g. a hotel's
   confirmation code).
   - The edit applies **optimistically** in the UI immediately.
   - The item shows a visible, non-blocking **pending-sync indicator**
     (e.g. a small clock glyph) until the write reconciles.
5. **Reconnect, no conflict:** connectivity returns; the queued edit sends
   and succeeds; the pending indicator clears with no further user action.
6. **Reconnect, with conflict:** another member (e.g. Priya) edited the
   *same item* (any field — conflict resolution is **row-level**, not
   field-level, per RESEARCH_FINDINGS' amendment) while this device was
   offline, and her write's `updated_at` is later than the queued local
   write's:
   - Priya's row wins in full — the local optimistic edit is discarded,
     even if it touched a *different* field than hers. This is the
     accepted v1 tradeoff (row-level LWW, not per-field merge) and must be
     tested deliberately, since it's the surprising case: editing an
     unrelated field can still be clobbered by someone else's concurrent
     edit to the same row.
   - The UI shows a non-destructive **"edited by Priya"** attribution —
     the user is told what happened, not left wondering why their change
     didn't stick.
   - If instead the local write's timestamp is later, the local edit wins
     and persists normally.
7. **No data loss on the losing side beyond the field(s) overwritten:** the
   device does not crash, does not re-queue the discarded edit in a loop,
   and the trip converges to one consistent state on both devices.
