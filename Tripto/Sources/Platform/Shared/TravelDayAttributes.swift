import ActivityKit
import Foundation

/// Live Activity attributes for a departing flight's countdown
/// (PLAN-signature-layer.md §D6). Frozen on W2-A's merge —
/// `LiveActivityCoordinator` (W2-B, app-side) starts/ends activities of
/// this type; `TravelDayActivityViews` (W2-B, widget-side) renders them.
///
/// Compiled into BOTH targets, same reason as `TripSnapshot` — kept free
/// of `Data/`/`Models/` references so the widget extension never needs
/// them.
public struct TravelDayAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        /// All rendered time is `Text(timerInterval:)`/
        /// `ProgressView(timerInterval:)` against these two dates — ticks
        /// with zero further updates once started (research §1). UTC
        /// instant, not zone-split like `SnapshotItem` — the widget only
        /// ever diffs these against `Date.now`.
        public var departsAt: Date
        /// The system dims/retires the Live Activity around this without
        /// the app doing anything — `LiveActivityCoordinator` sets it to
        /// `departsAt + 45m` (§D6), so a post-departure activity fades on
        /// its own with no foreground re-evaluation required.
        public var staleAt: Date

        public init(departsAt: Date, staleAt: Date) {
            self.departsAt = departsAt
            self.staleAt = staleAt
        }
    }

    public var tripId: UUID
    public var itemId: UUID
    /// Pre-formatted, e.g. "TP1234" — not (airline, number) parts, so the
    /// view layer never re-derives display text.
    public var flightName: String
    /// Pre-formatted, e.g. "LIS → BCN", same reasoning as `flightName`.
    public var routeText: String

    public init(tripId: UUID, itemId: UUID, flightName: String, routeText: String) {
        self.tripId = tripId
        self.itemId = itemId
        self.flightName = flightName
        self.routeText = routeText
    }
}
