import Foundation
import SwiftData

/// Builds the app-group `TripSnapshot` straight from the mirrored store.
/// `SyncStore` is the one `ModelActor` with correct isolation to read
/// SwiftData here — a main-context save is visible to it once saved, the
/// same guarantee every other `SyncStore` read already relies on
/// (`SnapshotWriter`'s doc comment covers who calls this and when).
extension SyncStore {
    /// "Upcoming + in-progress, max 6, soonest-first" (PLAN-signature-layer.md
    /// §D6) — the same ordering `HomeView`'s own `@Query(sort:
    /// \Trip.startDate)` already uses, so a widget's trip order matches
    /// what the app shows. `focusTripItems` covers ONE trip: the
    /// in-progress trip if any, else the soonest upcoming one — max 100,
    /// soonest-first. Both caps apply after the past-trip filter, so an
    /// in-progress trip (whose `startDate` is always <= `now`) is always
    /// eligible to be the focus trip even on an account with many trips.
    func buildSnapshot(now: Date = .now) throws -> TripSnapshot {
        let trips = try modelContext.fetch(FetchDescriptor<Trip>(sortBy: [SortDescriptor(\.startDate)]))
        let upcomingOrInProgress = Array(trips.filter { $0.bucket(asOf: now) != .past }.prefix(6))
        let snapshotTrips = upcomingOrInProgress.map(SnapshotTrip.init)

        let focusTrip = upcomingOrInProgress.first { $0.bucket(asOf: now) == .inProgress } ?? upcomingOrInProgress.first

        var focusItems: [SnapshotItem] = []
        if let focusTrip {
            let tripId = focusTrip.id
            // Confirmed only — the app-wide invariant is that `suggested`
            // (unreviewed, possibly mis-extracted imports) never render
            // until reviewed, and the snapshot's consumers are MORE public
            // than the in-app tabs: the Today widget, Siri's next-up
            // answer, and the lock-screen Live Activity (wave-2 review
            // should-fix). Mirrors TripView's trusted-surface query.
            let confirmedRaw = ItemStatus.confirmed.rawValue
            let items = try modelContext.fetch(
                FetchDescriptor<ItineraryItem>(
                    predicate: #Predicate { $0.tripId == tripId && $0.statusRaw == confirmedRaw },
                    sortBy: [SortDescriptor(\.startsAt)]
                )
            )
            focusItems = items.prefix(100).map(SnapshotItem.init)
        }

        return TripSnapshot(generatedAt: now, trips: snapshotTrips, focusTripItems: focusItems)
    }
}

private extension SnapshotTrip {
    init(_ trip: Trip) {
        self.init(
            id: trip.id, title: trip.title, coverGradient: trip.coverGradient,
            startDate: trip.startDate, endDate: trip.endDate, destination: trip.destination
        )
    }
}

private extension SnapshotItem {
    /// Pulls `fromIATA`/`toIATA`/`flightNo` out of `item.details` — the
    /// only fields from that blob that are safe to surface (never
    /// `confirmation`, `notes`, or anything in `details` beyond these
    /// three; see `TripSnapshot`'s doc comment).
    init(_ item: ItineraryItem) {
        let details = item.details
        self.init(
            id: item.id, tripId: item.tripId, title: item.title,
            category: SnapshotItem.Category(rawValue: item.category.rawValue) ?? .activity,
            startsAt: item.startsAt, endsAt: item.endsAt, tz: item.tz,
            fromIATA: details.fromIATA, toIATA: details.toIATA, flightNo: details.flightNo,
            locationName: item.locationName
        )
    }
}
