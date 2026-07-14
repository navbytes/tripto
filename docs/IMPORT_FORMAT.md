# Tripto Archive v1 — import/export format

The single JSON format Tripto uses for **migration import** (Settings →
"Import trips"), **data export** (Settings → "Export trips", BACKLOG §E3),
and deterministic test seeding. Design rationale in
[ROADMAP.md](ROADMAP.md) Phase 2: conversion from other apps' exports is
delegated to any LLM via the appendix prompt; the app only materializes this
format **deterministically** — no AI runs on import, so no AI-consent dialog
is involved (unlike paste/email import).

Status: v1 frozen 2026-07-13. Unknown JSON keys are **ignored** (forward
compatibility); a `version` greater than the app understands is **refused**
with an "update Tripto" message, never partially imported.

---

## 1. Envelope

```json
{
  "format": "tripto-archive",
  "version": 1,
  "exported_at": "2026-07-13T09:00:00Z",
  "trips": [ … ]
}
```

- `format` (string, required): must be `"tripto-archive"`.
- `version` (int, required): this document describes `1`.
- `exported_at` (ISO 8601 string, optional): informational only.
- `trips` (array, required): may be empty.

Hard bounds (import refuses beyond these): file ≤ 5 MB, ≤ 200 trips,
≤ 500 items per trip. A file that fails to decode, or violates the envelope
or bounds, imports **nothing** (atomic failure with a readable error).

## 2. Trip object

| Key | Type | Req | Notes |
|---|---|---|---|
| `id` | string | ✅ | Stable identifier from the source (any non-empty string). Drives idempotence (§5). |
| `title` | string | ✅ | |
| `destination` | string | — | Display string, e.g. `"Okinawa, Japan"`. Default: `title`. |
| `country_code` | string | — | ISO 3166-1 alpha-2 (`"JP"`). Default `""` (editable in-app). |
| `start_date` | `YYYY-MM-DD` | ✅ | Wall-calendar day (no zone), like the app's `DayDate`. **Missing/invalid → the whole trip is skipped and reported.** |
| `end_date` | `YYYY-MM-DD` | — | Default: `start_date`. |
| `trip_type` | string | — | `family` \| `friends` \| `solo`. Default `family`. Unknown → default. |
| `status` | string | — | `upcoming` \| `completed` \| `cancelled`. **`cancelled` trips are skipped and reported** (no cancelled state exists in-app). Otherwise informational — tense comes from dates. |
| `cover` | string | — | One of the app's cover-gradient names (see `TripFormView`). Unknown/missing → importer assigns one (stable rotation). |
| `travellers` | [string] | — | Display names of **non-account companions** (kids, grandparents, relatives). Each becomes a `trip_profiles` row. SHOULD NOT include the importing account owner (their profile is created server-side automatically; a duplicate here imports as a removable extra). |
| `items` | array | ✅ | May be empty. |
| `notes` | string | — | **Ignored in v1** (trips have no notes column); reported as dropped. Put meaningful notes on items. |

## 3. Item object

Common fields:

| Key | Type | Req | Notes |
|---|---|---|---|
| `id` | string | ✅ | Stable, unique within the trip. Drives idempotence (§5). |
| `category` | string | ✅ | `flight` \| `hotel` \| `activity` \| `food` \| `transport`. Unknown → item skipped and reported. |

An element of `items` that is not a valid item object (wrong JSON type,
unparseable) is likewise **skipped and reported** — it does not silently
vanish and does not abort the file (atomic failure in §1 is for files whose
envelope/structure can't be decoded at all).
| `title` | string | — | Defaults: flight → `"<airline> <flight_no>"` (or `"Flight <from_iata>–<to_iata>"`); others → capitalized category. |
| `starts_at` | string | ✅ | `YYYY-MM-DD` **or** `YYYY-MM-DDTHH:MM[:SS]` (naive local time) **or** full ISO 8601 with offset. Missing/invalid → item skipped and reported. |
| `ends_at` | string | — | Same forms as `starts_at`. |
| `tz` | string | — | IANA zone of `starts_at`'s local time. Resolution when absent: §4. |
| `location_name` | string | — | Flight default: `from_iata`. |
| `confirmation` | string | — | PNR / booking reference. |
| `notes` | string | — | Free text (disruptions, refunds, reminders). |

Per-category fields (all optional; the field vocabulary matches the app's
`ItemDetails` / paste-import extraction):

- **flight:** `airline`, `flight_no`, `from_iata`, `to_iata`, `seat`,
  `terminal`, `gate`, `arrival_tz` (IANA zone of `ends_at`)
- **hotel:** `room`
- **activity:** `ticket_ref`, `address`
- **food:** `party_size` (int), `reservation_name`, `address`
- **transport:** `provider`, `dropoff_location`, `arrival_tz`

## 4. Time resolution rules (importer contract)

Times are the known failure zone of trip apps (BUILD_PLAN §7.4); these rules
are deterministic and every result stays editable in-app:

1. **Zone of `starts_at`:** explicit `tz` → else (flight/transport with
   `from_iata`) the app's airport→zone table → else the device zone, and the
   import report flags "N item(s) assumed your device time zone — check
   times".
2. **Zone of `ends_at`:** explicit `arrival_tz` → else (flight/transport
   with `to_iata`) airport table → else same zone as `starts_at`.
3. Naive local datetimes are interpreted in the zone resolved above, then
   stored as UTC instants + the IANA zone alongside (the app's §7.4 model).
   An explicit ISO offset, when present, wins for the instant; the resolved
   zone is still stored for display.
4. **Date-only `starts_at`** gets a category default local time:
   flight 09:00 · hotel 15:00 (and date-only `ends_at` → 11:00) ·
   activity 10:00 · food 19:00 · transport 10:00.
5. Airports the table doesn't know fall through to rule 1's device-zone
   branch (reported). The table covers major hubs and is extended as
   archives hit gaps.

## 5. Idempotence & re-import

Importer derives all row ids as **UUIDv5** (RFC 4122, SHA-1) under the fixed
namespace UUID:

```
A0E4A1D6-5C2B-4E7F-8D3A-9B1C0F2E6D48
```

with names `trip:<trip.id>`, `item:<trip.id>/<item.id>`,
`profile:<trip.id>/<traveller display name>`.

- A trip is **skipped whole** and reported as "already imported" when either
  (a) its derived UUIDv5 already exists locally, or (b) its archive `id`
  itself parses as a UUID that matches an existing local trip — case (b) is
  what makes importing **your own export** a no-op, since export writes the
  app's row UUIDs as archive ids (§7) and UUIDv5 derivation has no fixed
  points. Re-importing any file a second time is safe and creates nothing.
  v1 does **not** merge changes into an existing trip; delete the trip
  in-app first to re-import it fresh.
- Consequence: export → import on the same account is a no-op (the round-trip
  regression test), via rule (b) on first import and rule (a) thereafter.

## 6. Import behavior (summary of the report)

- Runs entirely on-device: decode (strict, bounded) → map → insert through
  the app's normal offline-first write path; rows sync to the backend as the
  signed-in user (RLS applies; nothing privileged).
- Items land `status = "confirmed"`, `source = "manual"` — this is the
  user's own factual history, not an AI suggestion, so it bypasses the
  review inbox by design.
- The report lists: trips/items/profiles created; per-trip skips with
  reasons (`no start date`, `cancelled`, `already imported`); item skips
  (`unknown category`, `no start time`); zone-assumption count (§4.1);
  dropped trip-level `notes` (§2).

## 7. Export behavior (§E3 "Download my data")

Settings → "Export trips" writes this same format:

- Scope: every trip on this device (the local mirror = trips the user is a
  member of; server-side RLS is what scoped that set).
- `trips[].id` / `items[].id` are the app's row UUIDs (so a later import
  of your own export is recognized as already-imported), `travellers` are
  the trip's **unlinked** profiles, `status` is derived from dates
  (`completed` if ended before today, else `upcoming`).
- Not included in v1 (documented limitations): packing lists, item
  assignees, member/role information, trip-level notes (no such column).
  It's a data-portability export, not a full account backup — the backend
  remains the account of record.

## 8. Example

```json
{
  "format": "tripto-archive",
  "version": 1,
  "trips": [
    {
      "id": "2026-07-okinawa",
      "title": "Okinawa",
      "destination": "Okinawa, Japan",
      "country_code": "JP",
      "start_date": "2026-07-22",
      "end_date": "2026-07-26",
      "trip_type": "family",
      "status": "upcoming",
      "travellers": ["Asha", "Kiran", "Meera"],
      "items": [
        {
          "id": "uo844",
          "category": "flight",
          "starts_at": "2026-07-22T14:25",
          "ends_at": "2026-07-22T18:05",
          "airline": "HK Express",
          "flight_no": "UO844",
          "from_iata": "HKG",
          "to_iata": "OKA",
          "confirmation": "PNR001"
        },
        {
          "id": "car",
          "category": "transport",
          "title": "Rental car — Nissan X-trail (SUV)",
          "starts_at": "2026-07-22",
          "tz": "Asia/Tokyo",
          "provider": "Klook",
          "notes": "Booked 2026-04-01"
        }
      ]
    },
    {
      "id": "minimal",
      "title": "Weekend away",
      "start_date": "2025-03-01",
      "items": []
    }
  ]
}
```

---

## Appendix — converting another app's export with an LLM

Paste the following (plus your data) into any capable AI assistant:

> Convert my trip data below into **Tripto Archive v1** JSON. Rules:
> - Envelope: `{"format":"tripto-archive","version":1,"trips":[…]}`.
> - Follow the trip/item fields exactly as specified in sections 2–3 of
>   Tripto's IMPORT_FORMAT.md (categories: flight, hotel, activity, food,
>   transport; snake_case keys).
> - Give every trip and item a stable `id` (reuse the source's ids/PNRs
>   where possible — re-imports dedupe by id).
> - Dates `YYYY-MM-DD`; times as naive local `YYYY-MM-DDTHH:MM` **plus** the
>   IANA `tz` you know for that place/airport (and `arrival_tz` for
>   flights). Use `from_iata`/`to_iata` airport codes.
> - `country_code` is ISO 3166-1 alpha-2. `travellers` lists companions by
>   display name — do NOT include me (the account owner).
> - Bookings that aren't flights become items too: hotels → `hotel`,
>   car rentals/transfers → `transport`, attraction tickets → `activity`.
>   Put PNRs in `confirmation`, disruption/refund history in `notes`.
> - Skip nothing; if a trip has no known dates, still emit it (Tripto will
>   report it as skipped rather than guess).
>
> My data: …
