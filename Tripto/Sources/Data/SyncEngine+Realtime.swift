import Foundation
import Supabase

/// Realtime is triggers-only (SYNC_DESIGN.md: "Events are triggers, never
/// applied directly — the pull is the truth"). Nothing here ever decodes a
/// payload off the wire; every event just schedules the same debounced pull
/// a foreground/reconnect would have triggered anyway.
extension SyncEngine {
    /// One channel for the home list, filtered by nothing — RLS already
    /// scopes `trips` to "my trips", so any insert/update/delete visible to
    /// this session is relevant to Home.
    func startHomeRealtime() async {
        guard homeChannel == nil else { return }
        let channel = Supa.client.channel("home-trips")
        homeChannel = channel

        let stream = channel.postgresChange(AnyAction.self, schema: "public", table: SyncTable.trips.rawValue)
        homeChannelTask = Task {
            for await _ in stream {
                self.scheduleHomePull()
            }
        }
        await subscribeHomeChannel(channel, attempt: 1)
    }

    /// Subscribes `channel`, retrying with backoff (`SyncBackoff` — the same
    /// shape `SyncEngine+Push.swift`'s push retry uses) on failure instead
    /// of the previous log-and-forget behavior, which left realtime dead
    /// until the app relaunched while everything else looked fine. Gives up
    /// quietly past `maxRealtimeSubscribeAttempts` — realtime is
    /// triggers-only (this file's own doc comment), so a permanently-dead
    /// channel just means Home falls back to pull-on-foreground, not a
    /// broken app.
    ///
    /// Skips scheduling a retry while `isEffectivelyOffline` so a dead
    /// network doesn't spin this on a timer; also bails if `channel` is no
    /// longer `homeChannel` by the time a delayed retry fires (stopped or
    /// replaced while the retry was pending).
    private func subscribeHomeChannel(_ channel: RealtimeChannelV2, attempt: Int) async {
        do {
            try await channel.subscribeWithError()
        } catch {
            logDebug("startHomeRealtime: subscribe failed (attempt \(attempt)/\(Self.maxRealtimeSubscribeAttempts)): \(error)")
            guard attempt < Self.maxRealtimeSubscribeAttempts, !isEffectivelyOffline else {
                logDebug("startHomeRealtime: giving up on realtime subscribe")
                return
            }
            let delay = SyncBackoff.delay(attemptsSoFar: attempt)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.homeChannel === channel else { return }
                await self.subscribeHomeChannel(channel, attempt: attempt + 1)
            }
        }
    }

    func stopHomeRealtime() async {
        homeChannelTask?.cancel()
        homeChannelTask = nil
        if let channel = homeChannel {
            await Supa.client.removeChannel(channel)
        }
        homeChannel = nil
    }

    /// One channel per *open* trip, filtered to that trip's rows on each of
    /// its four tables. `TripView` (M2) calls this from `onAppear` and
    /// `stopObservingTrip` from `onDisappear`.
    func observeTrip(_ tripId: UUID) async {
        guard tripChannels[tripId] == nil else { return }
        let channel = Supa.client.channel("trip-\(tripId.uuidString)")
        tripChannels[tripId] = channel

        let filter = RealtimePostgresFilter.eq("trip_id", value: tripId)
        let observedTables: [SyncTable] = [.itineraryItems, .packingItems, .shareLinks, .invites]

        // One `Task { }` per table (not a `TaskGroup`) so each individually
        // inherits this actor's isolation via the standard `Task {}`
        // inherits-enclosing-isolation rule.
        let tasks = observedTables.map { table in
            let stream = channel.postgresChange(
                AnyAction.self, schema: "public", table: table.rawValue, filter: filter
            )
            return Task {
                for await _ in stream {
                    self.schedulePullTrip(tripId)
                }
            }
        }
        tripChannelTasks[tripId] = tasks
        await subscribeTripChannel(tripId, channel: channel, attempt: 1)
    }

    /// `observeTrip`'s half of the retry — see `subscribeHomeChannel`'s doc
    /// comment for the shared shape/rationale; the only difference is the
    /// "still current" check is against `tripChannels[tripId]`, since a
    /// trip channel is torn down per-trip (`stopObservingTrip`), not
    /// app-wide.
    private func subscribeTripChannel(_ tripId: UUID, channel: RealtimeChannelV2, attempt: Int) async {
        do {
            try await channel.subscribeWithError()
        } catch {
            logDebug("observeTrip(\(tripId)): subscribe failed (attempt \(attempt)/\(Self.maxRealtimeSubscribeAttempts)): \(error)")
            guard attempt < Self.maxRealtimeSubscribeAttempts, !isEffectivelyOffline else {
                logDebug("observeTrip(\(tripId)): giving up on realtime subscribe")
                return
            }
            let delay = SyncBackoff.delay(attemptsSoFar: attempt)
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard self.tripChannels[tripId] === channel else { return }
                await self.subscribeTripChannel(tripId, channel: channel, attempt: attempt + 1)
            }
        }
    }

    func stopObservingTrip(_ tripId: UUID) async {
        tripChannelTasks[tripId]?.forEach { $0.cancel() }
        tripChannelTasks[tripId] = nil
        if let channel = tripChannels[tripId] {
            await Supa.client.removeChannel(channel)
        }
        tripChannels[tripId] = nil
    }

    func stopAllRealtime() async {
        await stopHomeRealtime()
        for tripId in Array(tripChannels.keys) {
            await stopObservingTrip(tripId)
        }
    }
}
