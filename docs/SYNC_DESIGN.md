# Tripto sync design — local-first on Supabase (v1)

**Why this exists:** supabase-swift ships no offline store (RESEARCH_FINDINGS §1.2);
BUILD_PLAN §7.1 is amended to app-owned offline. This doc is the contract for the
data layer. Keep it boring: refetch-based pull, outbox push, row-level LWW.

## Principles

1. **SwiftData is the UI's only data source.** Views never await the network;
   they render `@Query` results instantly (BUILD_PLAN §7.2).
2. **Server is the source of truth; the mirror converges to it.** Local writes
   are optimistic and queued; a pull never clobbers rows with pending local ops.
3. **Row-level last-write-wins, by arrival.** Server triggers stamp
   `updated_at`/`updated_by`; the newest arrival wins. The UI shows a
   non-destructive "edited by {name}" chip from `updated_by` (§9.5 answer).
4. **Refetch, don't delta.** At family scale a trip payload is a few KB. Any
   realtime event or foreground transition just schedules a debounced re-pull of
   the affected trip. No event-sourcing, no per-row merge machinery.

## Local store (SwiftData `@Model`s, iOS 17)

Mirror tables 1:1 with server (`shared/types/tripto.swift` in the backend repo is
the field reference): `Profile`, `Trip`, `TripMember`, `TripProfile`,
`ItineraryItem`, `PackingItem`, `ShareLink`, `Invite`. All PKs are **client-
generated UUIDs** so offline create works. Every mirrored model carries nothing
extra — sync bookkeeping lives in `OutboxOp`, not on the entities.

`OutboxOp` (@Model): `id`, `createdAt`, `table`, `op` (upsert|delete), `rowId`,
`tripId?`, `payloadJSON` (full row snapshot for upsert), `attempts`,
`lastError?`. Rules: one pending upsert per `rowId` (new local edits **coalesce**
into it); a delete op replaces any pending upsert for that row.

## Engine (`SyncEngine`, an actor)

- **Push loop.** Triggered by: local mutation (debounced 300 ms), connectivity
  regained (NWPathMonitor), app foreground, post-pull. Sends ops FIFO per row via
  PostgREST `upsert` (`Prefer: resolution=merge-duplicates`) / `delete`.
  Success → remove op. RLS-denied (401/403) or check-violation → drop op, mark
  row `conflicted` in a lightweight `SyncIssue` record, surface toast; never
  retry forever (max 8 attempts, exponential backoff, jitter).
- **Pull.** `pullTrips()` = my trips + members + profiles (3 queries);
  `pullTrip(id)` = items + packing + share links + invites for one trip
  (parallel queries). Apply = upsert-by-id; then delete local rows absent from
  the server response **unless** they have a pending outbox op.
- **Realtime.** One `postgres_changes` channel per *open* trip (plus a cheap
  channel on `trips` filtered by membership for the home list). Any event →
  `schedulePull(tripId, debounce: 500ms)`. Events are triggers, never applied
  directly — the pull is the truth. (SDK ≥ 2.50 handles lifecycle reconnects;
  we still re-pull on foreground as belt-and-braces.)
- **Status surface.** `SyncStatus` observable: `offline` (path monitor),
  `pendingCount` (outbox), `lastSyncedAt`. Timeline banner per mockups v2:
  offline → amber banner; row-level pending → dashed border + "waiting to sync"
  chip (`pendingRowIds` set published by the engine).

## Auth

Sign in with Apple → `signInWithIdToken(provider: .apple)` (nonce-checked).
Session persists in Keychain (SDK default). `profiles` row is trigger-created
server-side. DEBUG builds also expose email-OTP sign-in (research risk #1:
hosted-project Apple-issuer 500s — if SiwA fails against our project, OTP keeps
development unblocked while support is escalated). Sign-out wipes the local
store (`ModelContainer` reset) and outbox.

## Write paths (examples)

- Create trip offline: insert `Trip` locally (client UUID) → outbox upsert →
  UI renders immediately; trigger-created membership arrives on next pull
  (engine also inserts a provisional local `TripMember(organizer)` so role-gated
  UI works offline; pull reconciles the real row, same values).
- Edit item: mutate model → coalesced outbox upsert → chip shows if offline.
- Delete trip: local cascade delete + outbox delete(trips, id). Server FK
  cascades mirror the local cascade.

## Non-goals (v1)

Field-level merge, tombstone history, partial-trip delta sync, background
fetch/push (BGTaskScheduler), multi-account. Revisit only with real scale
(PowerSync is the documented upgrade path — RESEARCH_FINDINGS §1.2).

## Acceptance (must pass; see docs/ACCEPTANCE.md)

Airplane-mode drill: full trip readable offline; create/edit/delete queue with
visible pending state; reconnect reconciles within seconds; a stale offline
edit overwrites by arrival and shows "edited by {me}" to the other member; no
duplicate rows after repeated offline/online cycles (idempotent upserts).
