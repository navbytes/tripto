import Foundation
import Supabase

enum SyncEngineError: Error {
    case invalidPayload
}

/// How a failed push should be handled — SYNC_DESIGN.md: "RLS-denied
/// (401/403) or check-violation → drop op, mark ... ; never retry forever
/// (max 8 attempts, exponential backoff, jitter)." `.permanent` is further
/// split by `retriable`, FIX #1's "tell the user, and let them act" design:
/// - `retriable: false` ("rejected") — RLS denied it or it violates a
///   constraint; sending the exact same payload again can never succeed.
/// - `retriable: true` ("exhausted") — an otherwise-transient failure that
///   burned through the retry budget; the network may come back, so a
///   later manual "Try again" can still succeed.
/// `SyncIssue.retriable` carries this through to the UI (`SyncIssueBanner`/
/// `SyncIssuesSheet`), which only offers "Try again" in the `true` case.
enum PushOutcome {
    case permanent(message: String, retriable: Bool)
    case transient(String)
}

/// Maps a thrown error to a `PushOutcome`. The spec frames the permanent
/// case as HTTP statuses (401/403/422), but `PostgrestBuilder.execute()`
/// throws a decoded `PostgrestError` (Postgres's own `code`/`message`, no
/// HTTP status attached) whenever PostgREST returns a JSON error body —
/// which RLS denials and constraint violations always do. `HTTPError`
/// (which does carry a status code) only surfaces for non-JSON error
/// bodies, so it's handled too, but in practice `PostgrestError.code` is
/// the reliable signal here.
enum PushErrorClassifier {
    /// Postgres SQLSTATE codes that mean "this write is fundamentally
    /// rejected" — retrying with the same payload can never succeed, the
    /// spec's "401/403/422" intent.
    private static let permanentPostgrestCodes: Set<String> = [
        "42501", // insufficient_privilege — RLS denied the write
        "23514", // check_violation
        "23505", // unique_violation
        "23503", // foreign_key_violation
    ]

    static func classify(_ error: Error, attemptsSoFar: Int, maxAttempts: Int) -> PushOutcome {
        let describedError = "\(error)"

        if let postgrestError = error as? PostgrestError {
            if let code = postgrestError.code, Self.permanentPostgrestCodes.contains(code) {
                return .permanent(message: "\(postgrestError.message) (code \(code))", retriable: false)
            }
            // An unrecognized PostgrestError (e.g. a transient 5xx PostgREST
            // still wraps as JSON) falls through to the attempt-budget check
            // below rather than being assumed permanent or transient outright.
            return outcomeRespectingBudget(attemptsSoFar: attemptsSoFar, maxAttempts: maxAttempts, message: describedError)
        }

        if let httpError = error as? HTTPError {
            let status = httpError.response.statusCode
            if [401, 403, 422].contains(status) {
                return .permanent(message: "HTTP \(status)", retriable: false)
            }
            return outcomeRespectingBudget(attemptsSoFar: attemptsSoFar, maxAttempts: maxAttempts, message: "HTTP \(status)")
        }

        // Network/transport errors (offline mid-flight, timeouts, decoding
        // hiccups) — always budget-limited retries, never immediately permanent.
        return outcomeRespectingBudget(attemptsSoFar: attemptsSoFar, maxAttempts: maxAttempts, message: describedError)
    }

    /// The budget-exhausted case is always `retriable: true` — unlike an
    /// outright rejection, nothing here says the *write itself* is invalid,
    /// only that this device ran out of patience; the network (or whatever
    /// transient condition this was) may be fine again by the time the user
    /// taps "Try again."
    private static func outcomeRespectingBudget(attemptsSoFar: Int, maxAttempts: Int, message: String) -> PushOutcome {
        if attemptsSoFar + 1 >= maxAttempts {
            return .permanent(message: "gave up after \(attemptsSoFar + 1) attempts: \(message)", retriable: true)
        }
        return .transient(message)
    }
}

extension SyncEngine {
    /// Debounced push trigger (SYNC_DESIGN.md: local mutation, 300ms).
    ///
    /// If a flush is already in progress, this must *not* cancel
    /// `pushDebounceTask` — once that task is past its debounce sleep, it
    /// *is* the task currently awaiting `flushPush()`'s network calls, and
    /// cancelling it aborts an in-flight PostgREST request (confirmed live:
    /// two triggers landing close together — one from `enqueueUpsert`, one
    /// from `start()`'s post-pull call — cancelled a push mid-request with
    /// `NSURLErrorCancelled`). Instead, just flag that another pass is
    /// needed; `flushPush()`'s own loop picks it up once it's free.
    func schedulePush() {
        guard !isPushing else {
            pushRequestedWhileBusy = true
            return
        }
        pushDebounceTask?.cancel()
        pushDebounceTask = Task {
            try? await Task.sleep(nanoseconds: Self.pushDebounceMilliseconds * 1_000_000)
            guard !Task.isCancelled else { return }
            await flushPush()
        }
    }

    /// Sends every queued op FIFO, looping if more ops were enqueued (or a
    /// push was otherwise requested) while this flush was already running,
    /// so nothing enqueued mid-flush has to wait for a separate debounce
    /// cycle to be picked up.
    func flushPush() async {
        guard !isPushing else { return }
        guard !isEffectivelyOffline else { return }
        isPushing = true
        defer { isPushing = false }

        repeat {
            pushRequestedWhileBusy = false

            let ops: [OutboxOpSnapshot]
            do {
                ops = try await store.pendingOps()
            } catch {
                logDebug("flushPush: failed to load pending ops: \(error)")
                break
            }

            for op in ops {
                guard !isEffectivelyOffline else { break }
                await push(op)
            }
        } while pushRequestedWhileBusy && !isEffectivelyOffline

        await refreshStatusCounts()
    }

    private func push(_ op: OutboxOpSnapshot) async {
        do {
            switch op.op {
            case .upsert:
                try await pushUpsert(op)
            case .delete:
                try await pushDelete(op)
            }
            try await store.markPushed(opId: op.id)
        } catch {
            await handlePushFailure(op: op, error: error)
        }
    }

    /// Deliberately *not* PostgREST's native `.upsert()` (`INSERT ... ON
    /// CONFLICT DO UPDATE`) — plain insert, falling back to update on a
    /// conflict. Two independent RLS interactions rule out `.upsert()`
    /// here, both confirmed live against this project:
    ///
    /// 1. `RETURNING` (the row PostgREST hands back) is itself filtered by
    ///    the table's SELECT policy. `trips_select` requires
    ///    `is_trip_member(id)`, which only becomes true once
    ///    `on_trip_created`'s trigger has inserted the `trip_members` row —
    ///    asking for a representation back races that trigger. Fixed by
    ///    `returning: .minimal` (push never reads the response body anyway;
    ///    the next pull is the source of truth per SYNC_DESIGN.md).
    /// 2. More fundamentally: for `INSERT ... ON CONFLICT DO UPDATE`,
    ///    Postgres evaluates *both* the INSERT policy and the UPDATE
    ///    policy against the row, regardless of whether a conflict is
    ///    actually hit (documented Postgres RLS behavior). `trips_update`
    ///    requires `trip_role(id) = 'organizer'`, which — again — isn't
    ///    satisfiable until the very trigger this same statement would
    ///    fire has run. A brand-new trip's *first* push therefore always
    ///    403s under a native upsert, `returning:` notwithstanding.
    ///
    /// Splitting into insert-first/update-on-conflict sidesteps both: a
    /// plain INSERT only ever evaluates the INSERT policy, and a plain
    /// UPDATE (reached only once the row — and its trigger-created
    /// membership — already exists) only ever evaluates the UPDATE policy.
    private func pushUpsert(_ op: OutboxOpSnapshot) async throws {
        guard let data = op.payloadJSON.data(using: .utf8) else {
            throw SyncEngineError.invalidPayload
        }
        // Passthrough decode: the payload's keys are already the exact
        // column names PostgREST expects (see JSONCoding.passthroughDecoder's
        // doc comment) — re-running `.convertFromSnakeCase` here would
        // mangle them right before they go back out over the wire.
        let values = try JSONCoding.passthroughDecoder.decode(AnyJSON.self, from: data)

        do {
            try await Supa.client
                .from(op.table.rawValue)
                .insert(values, returning: .minimal)
                .execute()
        } catch let error as PostgrestError where error.code == "23505" {
            guard op.table != .itemAssignees else {
                // `item_assignees`' PK *is* (item_id, profile_id) — every
                // column this row has. A conflict here means the assignment
                // already exists exactly as intended, so there is nothing to
                // update (and no `id` column to `.eq(...)` against even if
                // there were — see `ItemAssignee`'s doc comment). Treat the
                // conflict as success, unlike every other mirrored table.
                return
            }
            // unique_violation on `id` — this row already exists server-side
            // (a later edit of something this device previously created),
            // not a first-time create. Fall back to a plain update.
            try await Supa.client
                .from(op.table.rawValue)
                .update(values, returning: .minimal)
                .eq("id", value: op.rowId)
                .execute()
        }
    }

    private func pushDelete(_ op: OutboxOpSnapshot) async throws {
        guard op.table != .itemAssignees else {
            // Composite PK, no `id` column — `op.rowId` is only
            // `ItemAssignee.compositeId(...)`, a local dedup key with no
            // server-side meaning. `enqueueDeleteItemAssignee` stashed the
            // real pair in `payloadJSON` (the *decoding* — not passthrough —
            // decoder: this payload was encoded from a real `ItemAssigneeDTO`
            // via `JSONCoding.encoder`, so it needs the matching
            // `.convertFromSnakeCase` decode back into that same DTO shape,
            // unlike `pushUpsert`'s `AnyJSON` passthrough above).
            guard let data = op.payloadJSON.data(using: .utf8),
                let dto = try? JSONCoding.decoder.decode(ItemAssigneeDTO.self, from: data)
            else {
                throw SyncEngineError.invalidPayload
            }
            try await Supa.client
                .from(op.table.rawValue)
                .delete()
                .eq("item_id", value: dto.itemId)
                .eq("profile_id", value: dto.profileId)
                .execute()
            return
        }
        try await Supa.client
            .from(op.table.rawValue)
            .delete()
            .eq("id", value: op.rowId)
            .execute()
    }

    private func handlePushFailure(op: OutboxOpSnapshot, error: Error) async {
        let outcome = PushErrorClassifier.classify(
            error, attemptsSoFar: op.attempts, maxAttempts: Self.maxPushAttempts
        )
        switch outcome {
        case .permanent(let message, let retriable):
            logDebug("push gave up for \(op.table.rawValue)/\(op.rowId): \(message)")
            try? await store.markPermanentFailure(
                opId: op.id, rowId: op.rowId, table: op.table, message: message, retriable: retriable
            )
        case .transient(let message):
            logDebug("push retrying \(op.table.rawValue)/\(op.rowId) (attempt \(op.attempts + 1)): \(message)")
            try? await store.markTransientFailure(opId: op.id, error: message)
            scheduleRetry(afterAttempts: op.attempts + 1)
        }
        await refreshStatusCounts()
    }

    /// Exponential backoff with jitter, capped at 60s (`SyncBackoff`, also
    /// reused by `SyncEngine+Realtime.swift`'s subscribe retry), so a
    /// transient failure retries on its own rather than waiting for the
    /// next unrelated mutation to happen to trigger a push.
    ///
    /// Deliberately an independent, untracked `Task` rather than reusing
    /// `pushDebounceTask` — this runs from inside `flushPush()`'s own loop
    /// (`isPushing` is true), so `pushDebounceTask` may well be *this very
    /// task*; cancelling it here would mark the still-executing flush
    /// cancelled and could abort its remaining ops' network calls.
    private func scheduleRetry(afterAttempts attempts: Int) {
        let delay = SyncBackoff.delay(attemptsSoFar: attempts)
        Task {
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.schedulePush()
        }
    }
}
