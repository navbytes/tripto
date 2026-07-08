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
        do {
            try await channel.subscribeWithError()
        } catch {
            logDebug("startHomeRealtime: subscribe failed: \(error)")
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
        do {
            try await channel.subscribeWithError()
        } catch {
            logDebug("observeTrip(\(tripId)): subscribe failed: \(error)")
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
