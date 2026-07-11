import SwiftUI
import WidgetKit

/// `TriptoWidgets` extension entry point (PLAN-signature-layer.md §D6: one
/// extension target holds every widget + the Live Activity's
/// `ActivityConfiguration` together — research §2).
///
/// W2-A shipped one minimal placeholder proving the target builds, embeds,
/// and reads `TripSnapshot` from the App Group container with no SwiftData
/// linked in. W2-B (this) replaces it with the real gallery widgets and the
/// Live Activity configuration.
@main
struct TriptoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        NextTripWidget()
        TodayPlanWidget()
        TravelDayActivityWidget()
    }
}
