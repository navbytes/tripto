import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

/// PLAN-signature-layer.md §D7: attached to `SnapshotWriter`'s frozen
/// `onWrite` hook (`TriptoApp.init`) — same moment, same debounce as every
/// other glanceable surface (§D6: "one pipeline"). Full re-index on every
/// write: at Tripto's dozens-scale, delete-all-then-add is simpler than an
/// incremental diff and just as correct (research §4).
enum SpotlightIndexer {
    /// The one category this app indexes — wiped in a single call on
    /// sign-out/clear (research §4's "the only real decision":
    /// `uniqueIdentifier == trip UUID`, stable forever).
    static let domainIdentifier = "trips"

    /// `SnapshotWriter.onWrite`'s exact signature — pass this function
    /// itself as the handler: `setOnWrite(SpotlightIndexer.handle)`. `nil`
    /// (sign-out/clear) wipes the domain and stops there; a snapshot
    /// re-indexes its trips in full.
    ///
    /// `onWrite` is synchronous (`(TripSnapshot?) -> Void`), so this kicks
    /// off an unstructured `Task` to reach Core Spotlight's async API.
    /// ponytail: two `onWrite` calls close enough together could race each
    /// other's delete/add pair — `SnapshotWriter`'s 800ms debounce makes
    /// that rare in practice, and the next write always reconciles the
    /// index, so it's a self-healing gap, not a persistent-drift risk. Add a
    /// serial queue here if back-to-back writes ever become common.
    static func handle(_ snapshot: TripSnapshot?) {
        Task {
            do {
                try await CSSearchableIndex.default().deleteSearchableItems(withDomainIdentifiers: [domainIdentifier])
                guard let trips = snapshot?.trips, !trips.isEmpty else { return }
                try await CSSearchableIndex.default().indexSearchableItems(trips.map(searchableItem))
            } catch {
                #if DEBUG
                print("[SpotlightIndexer] index failed: \(error)")
                #endif
            }
        }
    }

    /// Title/destination/dates only — nothing a confirmation code, note, or
    /// email could hide in (§D6/§D7 log hygiene: `SnapshotTrip` has no such
    /// field to begin with, the same sanitized-by-construction guarantee as
    /// the snapshot itself).
    private static func searchableItem(for trip: SnapshotTrip) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = trip.title
        attributes.contentDescription = "\(TripDateRangeFormat.text(start: trip.startDate, end: trip.endDate)) \u{00B7} \(trip.destination)"
        return CSSearchableItem(uniqueIdentifier: trip.id.uuidString, domainIdentifier: domainIdentifier, attributeSet: attributes)
    }
}
