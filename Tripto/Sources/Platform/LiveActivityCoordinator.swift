import ActivityKit
import Foundation

/// Starts/ends the travel-day Live Activity (PLAN-signature-layer.md §D6).
/// `evaluate()` is foreground-only by ActivityKit's own rule (research §1:
/// `Activity.request` throws `.visibility` from the background) — the only
/// call site is `RootView`'s `scenePhase == .active` hook. Reads
/// `TripSnapshot.load()`, the same one glanceable-surface contract every
/// other consumer reads, rather than SwiftData directly — no `ModelContext`
/// hop needed to decide whether to start a countdown.
enum LiveActivityCoordinator {
    /// ActivityKit's own max-active budget (research §1) — starting any
    /// later than this before departure would just have the system
    /// force-end the activity before the flight leaves, so it's also the
    /// latest point it's worth starting one at all.
    static let startWindow: TimeInterval = 8 * 3600
    /// How long past departure a running activity is left alone before
    /// this evaluator ends it outright — matches `ContentState.staleAt`
    /// (`departsAt + postDepartureGrace`), so "we end it" and "the system
    /// marks it stale" land at the same moment either way.
    static let postDepartureGrace: TimeInterval = 45 * 60

    // MARK: - Pure decision logic (unit tested — see `LiveActivityCoordinatorTests`)

    /// The soonest still-upcoming flight in `items`, or `nil`. `items` is
    /// always one trip's worth (`TripSnapshot.focusTripItems`), so no
    /// per-trip grouping is needed here.
    static func nextFlight(in items: [SnapshotItem], now: Date) -> SnapshotItem? {
        items
            .filter { $0.category == .flight && $0.startsAt > now }
            .min { $0.startsAt < $1.startsAt }
    }

    /// Whether `flight` is inside the start window and isn't already
    /// running. Closed upper bound (`<=`) — a flight exactly 8h out is
    /// still fair game the instant this evaluator sees it.
    static func shouldStart(flight: SnapshotItem, runningItemIds: Set<UUID>, now: Date) -> Bool {
        guard flight.startsAt > now, flight.startsAt <= now.addingTimeInterval(startWindow) else { return false }
        return !runningItemIds.contains(flight.id)
    }

    /// Which currently-running activities (item id -> their `departsAt`)
    /// are past the post-departure grace period and should be ended.
    static func itemIdsToEnd(runningDepartures: [UUID: Date], now: Date) -> Set<UUID> {
        Set(runningDepartures.filter { now > $0.value.addingTimeInterval(postDepartureGrace) }.keys)
    }

    static func flightName(for item: SnapshotItem) -> String {
        item.flightNo ?? item.title
    }

    static func routeText(for item: SnapshotItem) -> String {
        guard let from = item.fromIATA, let to = item.toIATA else { return item.locationName }
        return "\(from) \u{2192} \(to)"
    }

    // MARK: - Side effects (ActivityKit itself — exercised live in sim, not by unit tests; see W2-B.md)

    /// ponytail: not re-entrancy-guarded — two `evaluate()` calls racing
    /// within the same instant (rapid foreground churn) could both pass
    /// the "not already running" check and both call `.request`,
    /// producing a harmless duplicate Activity for the same flight. Add a
    /// serializing actor if that's ever observed live; not worth one for a
    /// rare, cosmetic-only race.
    static func evaluate(now: Date = .now) async {
        let running = Activity<TravelDayAttributes>.activities
        let runningDepartures = Dictionary(
            uniqueKeysWithValues: running.map { ($0.attributes.itemId, $0.content.state.departsAt) }
        )

        for itemId in itemIdsToEnd(runningDepartures: runningDepartures, now: now) {
            guard let activity = running.first(where: { $0.attributes.itemId == itemId }) else { continue }
            await activity.end(nil, dismissalPolicy: .immediate)
        }

        guard let flight = nextFlight(in: TripSnapshot.load()?.focusTripItems ?? [], now: now) else { return }
        guard shouldStart(flight: flight, runningItemIds: Set(runningDepartures.keys), now: now) else { return }

        let staleAt = flight.startsAt.addingTimeInterval(postDepartureGrace)
        let attributes = TravelDayAttributes(
            tripId: flight.tripId, itemId: flight.id,
            flightName: flightName(for: flight), routeText: routeText(for: flight)
        )
        let content = ActivityContent(
            state: TravelDayAttributes.ContentState(departsAt: flight.startsAt, staleAt: staleAt),
            staleDate: staleAt
        )
        do {
            _ = try Activity.request(attributes: attributes, content: content)
        } catch {
            #if DEBUG
            print("[LiveActivityCoordinator] request failed: \(error)")
            #endif
        }
    }
}
