import SwiftUI
import WidgetKit

/// `TriptoWidgets` extension entry point (PLAN-signature-layer.md §D6: one
/// extension target holds every widget + the Live Activity's
/// `ActivityConfiguration` together — research §2).
///
/// W2-A ships one minimal placeholder so the target builds, embeds, and
/// proves it can read `TripSnapshot` from the App Group container with no
/// SwiftData linked in. W2-B replaces `PlaceholderTripWidget` with the real
/// `NextTripWidget`/`TodayPlanWidget` gallery entries and adds the
/// `ActivityConfiguration(for: TravelDayAttributes.self)`.
@main
struct TriptoWidgetsBundle: WidgetBundle {
    var body: some Widget {
        PlaceholderTripWidget()
    }
}

/// W2-A's proof-of-life widget: renders the next trip's title straight
/// from `TripSnapshot.load()` (or the empty state) — nothing here ever
/// opens SwiftData (D6: "Widgets never open the SwiftData store").
struct PlaceholderTripWidget: Widget {
    let kind = "PlaceholderTripWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: PlaceholderTripProvider()) { entry in
            PlaceholderTripView(entry: entry)
                .containerBackground(for: .widget) { CoverGradient.dusk }
        }
        .configurationDisplayName("Tripto")
        .description("Your next trip, at a glance.")
        .supportedFamilies([.systemSmall])
    }
}

struct PlaceholderTripEntry: TimelineEntry {
    let date: Date
    let tripTitle: String?
}

struct PlaceholderTripProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderTripEntry {
        PlaceholderTripEntry(date: .now, tripTitle: "Lisbon")
    }

    func getSnapshot(in context: Context, completion: @escaping (PlaceholderTripEntry) -> Void) {
        completion(currentEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderTripEntry>) -> Void) {
        // W2-A budget: one entry, reloaded by the app's own
        // `WidgetCenter.shared.reloadAllTimelines()` after every snapshot
        // write (`SnapshotWriter`) rather than a timeline-internal
        // schedule — `NextTripWidget`/`TodayPlanWidget` (W2-B) own the
        // real midnight-rollover policy (§D6).
        completion(Timeline(entries: [currentEntry()], policy: .after(.now.addingTimeInterval(3600))))
    }

    private func currentEntry() -> PlaceholderTripEntry {
        PlaceholderTripEntry(date: .now, tripTitle: TripSnapshot.load()?.trips.first?.title)
    }
}

struct PlaceholderTripView: View {
    let entry: PlaceholderTripEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Spacer()
            Text(entry.tripTitle ?? "Plan a trip in Tripto")
                .font(Typo.display(Typo.Size.title))
                .foregroundStyle(.white)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(Spacing.md)
    }
}
