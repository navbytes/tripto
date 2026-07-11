import SwiftUI
import WidgetKit

/// Small + medium "next trip" glance (PLAN-signature-layer.md §D6). Reads
/// only `TripSnapshot.load()` — the widget extension never opens SwiftData
/// (D6: "Widgets never open the SwiftData store"). `snapshot.trips` is
/// already "upcoming + in-progress, soonest-first, in-progress sorts
/// first" (`SyncStore+Snapshot.swift`'s doc comment — an in-progress
/// trip's `startDate` is always <= now, so it sorts ahead of every
/// still-future upcoming trip by construction), so `trips.first` IS "the
/// next trip" with no extra sort/filter needed here.
struct NextTripWidget: Widget {
    let kind = "NextTripWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: NextTripProvider()) { entry in
            NextTripWidgetView(trip: entry.trip, now: entry.date)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .containerBackground(for: .widget) {
                    // `from(key:)` already falls back to `defaultGradient`
                    // (dusk) for a `nil` key — covers "no trip yet" (§D6's
                    // shared placeholder treatment) with the same call
                    // used for a real trip's own gradient.
                    CoverGradient.from(key: entry.trip?.coverGradient)
                }
        }
        .configurationDisplayName("Next Trip")
        .description("Your next trip, at a glance.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct NextTripEntry: TimelineEntry {
    let date: Date
    let trip: SnapshotTrip?
}

struct NextTripProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextTripEntry {
        NextTripEntry(date: .now, trip: NextTripProvider.placeholderTrip)
    }

    func getSnapshot(in context: Context, completion: @escaping (NextTripEntry) -> Void) {
        completion(NextTripEntry(date: .now, trip: TripSnapshot.load()?.trips.first))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<NextTripEntry>) -> Void) {
        let now = Date.now
        let entry = NextTripEntry(date: now, trip: TripSnapshot.load()?.trips.first)
        // §D6: "in N days" only changes at local midnight — one entry is
        // enough; the system reloads at midnight, and `SnapshotWriter`
        // triggers an extra reload on every real data change.
        completion(Timeline(entries: [entry], policy: .after(Calendar.current.nextMidnight(after: now))))
    }

    static let placeholderTrip = SnapshotTrip(
        id: UUID(), title: "Lisbon", coverGradient: "dusk",
        startDate: Date.now.addingTimeInterval(12 * 86_400),
        endDate: Date.now.addingTimeInterval(18 * 86_400),
        destination: "Lisbon, Portugal"
    )
}

struct NextTripWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let trip: SnapshotTrip?
    var now: Date = .now

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverGradient.textScrim
            if let trip {
                populated(trip)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityLabel(for: trip))
            } else {
                Text("Plan a trip in Tripto")
                    .font(Typo.display(Typo.Size.title))
                    .foregroundStyle(.white)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(Spacing.lg)
        .widgetURL(trip.flatMap { URL(string: "tripto://trip/\($0.id.uuidString)") })
    }

    @ViewBuilder
    private func populated(_ trip: SnapshotTrip) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            pill(for: trip)
            Text(trip.title)
                .font(Typo.display(Typo.Size.display))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if family == .systemMedium, !trip.destination.isEmpty {
                Text(trip.destination)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
            }
        }
    }

    private func pill(for trip: SnapshotTrip) -> some View {
        Text(trip.isInProgress(asOf: now) ? "In progress" : "in \(pluralDayText(trip.daysUntilStart(asOf: now)))")
            .font(Typo.body(Typo.Size.caption, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(Palette.coverPillFill, in: Capsule())
    }

    private func accessibilityLabel(for trip: SnapshotTrip) -> String {
        var parts = [trip.title]
        if !trip.destination.isEmpty { parts.append(trip.destination) }
        parts.append(trip.isInProgress(asOf: now) ? "in progress" : "starts in \(pluralDayText(trip.daysUntilStart(asOf: now)))")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Shared trip day-math (mirrors `Models/Trip+Bucketing.swift`)

extension SnapshotTrip {
    /// Reimplemented, not imported — `Models/` (where `TripDateBucketing`
    /// lives) never compiles into `TriptoWidgets` (D6: no SwiftData/model
    /// types in the widget extension). Kept behaviorally identical to
    /// `TripCard`'s own pill: same day-granular `Calendar.current
    /// .startOfDay` comparison, so a trip's "in N days"/"in progress"
    /// reads identically on the widget and in the app.
    func isInProgress(asOf date: Date, calendar: Calendar = .current) -> Bool {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let today = calendar.startOfDay(for: date)
        return start <= today && today <= end
    }

    func daysUntilStart(asOf date: Date, calendar: Calendar = .current) -> Int {
        let start = calendar.startOfDay(for: startDate)
        let today = calendar.startOfDay(for: date)
        return calendar.dateComponents([.day], from: today, to: start).day ?? 0
    }
}

/// Shared by `TodayPlanWidget.swift` too (same target — no import needed).
func pluralDayText(_ days: Int) -> String { "\(days) day\(days == 1 ? "" : "s")" }

extension Calendar {
    /// The next local-midnight boundary strictly after `date` — both
    /// widgets' reload policy (§D6: "days until"/"today" only ever change
    /// at midnight). Shared by `TodayPlanWidget.swift` too.
    func nextMidnight(after date: Date) -> Date {
        let today = startOfDay(for: date)
        return self.date(byAdding: .day, value: 1, to: today) ?? date.addingTimeInterval(86_400)
    }
}
