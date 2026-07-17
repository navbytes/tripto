import SwiftUI
import WidgetKit

/// Medium + large "today" glance (PLAN-signature-layer.md §D6) — the next
/// item and a few after it, from the ONE focus trip's items
/// (`TripSnapshot.focusTripItems`). Reads only the App Group snapshot,
/// same rule as `NextTripWidget` (D6: no SwiftData in the extension).
///
/// "Today" is bucketed on the *device's* current calendar day
/// (`Calendar.current`), not each item's own tz (§7.4's rule for the
/// itinerary SCREEN's day-section headers) — deliberately: this widget
/// answers "what should I glance at right now," which is the viewer's own
/// present calendar day (and `Calendar.current`'s zone already follows the
/// device while traveling), not a mix of different items' origin-city
/// dates. Each item's own *time* is still rendered in its own zone
/// (`SnapshotItem.tz`) below — §7.4 governs display, not this bucketing
/// choice.
struct TodayPlanWidget: Widget {
    let kind = "TodayPlanWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: TodayPlanProvider()) { entry in
            TodayPlanWidgetView(kind: entry.kind, referenceDate: entry.date)
                .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                .containerBackground(for: .widget) {
                    if case .noTrip = entry.kind {
                        CoverGradient.dusk
                    } else {
                        Palette.elevated
                    }
                }
        }
        .configurationDisplayName("Today's Plan")
        .description("What's next today, on your current trip.")
        .supportedFamilies([.systemMedium, .systemLarge])
    }
}

enum TodayPlanKind: Equatable {
    case noTrip
    case noPlansToday(trip: SnapshotTrip)
    /// `nextUpItemId` is `nil` once every item on this reference day has
    /// already started — `items` still lists the whole day rather than
    /// going blank, just without the "Next up" callout.
    case items(trip: SnapshotTrip, items: [SnapshotItem], nextUpItemId: UUID?)
}

struct TodayPlanEntry: TimelineEntry {
    let date: Date
    let kind: TodayPlanKind
}

enum TodayPlanBuilder {
    /// `snapshot.trips.first` IS the focus trip whose items are in
    /// `focusTripItems` — see `NextTripWidget`'s doc comment for why
    /// `buildSnapshot`'s two selections always agree.
    static func entry(at date: Date, snapshot: TripSnapshot?) -> TodayPlanEntry {
        guard let trip = snapshot?.trips.first else {
            return TodayPlanEntry(date: date, kind: .noTrip)
        }
        let todays = (snapshot?.focusTripItems ?? [])
            .filter { Calendar.current.isDate($0.startsAt, inSameDayAs: date) }
            .sorted { $0.startsAt < $1.startsAt }
        guard !todays.isEmpty else {
            return TodayPlanEntry(date: date, kind: .noPlansToday(trip: trip))
        }
        let upcoming = todays.filter { $0.startsAt >= date }
        let display = upcoming.isEmpty ? todays : upcoming
        return TodayPlanEntry(date: date, kind: .items(trip: trip, items: display, nextUpItemId: upcoming.first?.id))
    }

    /// Timeline reload points (§D6 "midnight timeline policy"): now, each
    /// remaining today-item's own start (so "Next up" advances with no
    /// fresh app-triggered reload as the day passes), and next local
    /// midnight (so "today" itself rolls over) — capped well inside the
    /// system's reload budget (research §2: plan around daily-ish
    /// granularity, not sub-5-minute cadence).
    static func reloadDates(after now: Date, snapshot: TripSnapshot?) -> [Date] {
        let remainingStartsToday = (snapshot?.focusTripItems ?? [])
            .map(\.startsAt)
            .filter { $0 > now && Calendar.current.isDate($0, inSameDayAs: now) }
            .sorted()
        let capped = Array(remainingStartsToday.prefix(9)) // + now + midnight <= 11
        return ([now] + capped + [Calendar.current.nextMidnight(after: now)]).sorted()
    }
}

struct TodayPlanProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayPlanEntry {
        TodayPlanBuilder.entry(at: .now, snapshot: TodayPlanProvider.placeholderSnapshot)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayPlanEntry) -> Void) {
        completion(TodayPlanBuilder.entry(at: .now, snapshot: TripSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayPlanEntry>) -> Void) {
        let now = Date.now
        let snapshot = TripSnapshot.load()
        let entries = TodayPlanBuilder.reloadDates(after: now, snapshot: snapshot)
            .map { TodayPlanBuilder.entry(at: $0, snapshot: snapshot) }
        completion(Timeline(entries: entries, policy: .after(Calendar.current.nextMidnight(after: now))))
    }

    static let placeholderSnapshot: TripSnapshot = {
        let tripId = UUID()
        let trip = SnapshotTrip(
            id: tripId, title: "Lisbon", coverGradient: "dusk",
            startDate: .now, endDate: .now.addingTimeInterval(6 * 86_400), destination: "Lisbon, Portugal"
        )
        let items = [
            SnapshotItem(
                id: UUID(), tripId: tripId, title: "TAP TP1234", category: .flight,
                startsAt: .now.addingTimeInterval(3600), endsAt: nil, tz: "Europe/Lisbon",
                fromIATA: "JFK", toIATA: "LIS", flightNo: "TP1234", locationName: "JFK"
            ),
            SnapshotItem(
                id: UUID(), tripId: tripId, title: "Belém Tower", category: .activity,
                startsAt: .now.addingTimeInterval(4 * 3600), endsAt: nil, tz: "Europe/Lisbon",
                fromIATA: nil, toIATA: nil, flightNo: nil, locationName: "Belém, Lisbon"
            )
        ]
        return TripSnapshot(generatedAt: .now, trips: [trip], focusTripItems: items)
    }()
}

struct TodayPlanWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let kind: TodayPlanKind
    var referenceDate: Date = .now

    private var maxRows: Int { family == .systemLarge ? 4 : 2 }

    var body: some View {
        switch kind {
        case .noTrip:
            emptyPlaceholder
        case .noPlansToday(let trip):
            noPlans(trip: trip)
        case .items(let trip, let items, let nextUpItemId):
            populated(trip: trip, items: items, nextUpItemId: nextUpItemId)
        }
    }

    private var emptyPlaceholder: some View {
        ZStack(alignment: .bottomLeading) {
            CoverGradient.textScrim
            Text("Plan a trip in Tripto")
                .font(Typo.display(Typo.Size.title))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(Spacing.lg)
    }

    private func noPlans(trip: SnapshotTrip) -> some View {
        let days = trip.daysUntilStart(asOf: referenceDate)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(trip.title)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.amberInk)
            Text(days > 0 ? "Starts in \(pluralDayText(days))" : "No plans for today")
                .font(Typo.display(Typo.Size.title))
                .foregroundStyle(Palette.ink)
        }
        .accessibilityElement(children: .combine)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.lg)
        .widgetURL(URL(string: "tripto://trip/\(trip.id.uuidString)"))
    }

    private func populated(trip: SnapshotTrip, items: [SnapshotItem], nextUpItemId: UUID?) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text(trip.title)
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.amberInk)
                Spacer()
                Text("Today")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }
            .accessibilityElement(children: .combine)

            ForEach(items.prefix(maxRows)) { item in
                TodayPlanRow(item: item, isNext: item.id == nextUpItemId)
            }

            if items.count > maxRows {
                Text("+\(items.count - maxRows) more today")
                    .font(Typo.body(Typo.Size.helper))
                    .foregroundStyle(Palette.slate)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(Spacing.lg)
        .widgetURL(URL(string: "tripto://trip/\(trip.id.uuidString)"))
    }
}

private struct TodayPlanRow: View {
    let item: SnapshotItem
    let isNext: Bool

    var body: some View {
        HStack(spacing: Spacing.sm) {
            SnapshotCategoryTile(category: item.category)
            VStack(alignment: .leading, spacing: 0) {
                if isNext {
                    Text("Next up")
                        .font(Typo.body(Typo.Size.helper, weight: .semibold))
                        .foregroundStyle(Palette.amberInk)
                }
                Text(item.title)
                    .font(Typo.body(Typo.Size.body, weight: isNext ? .semibold : .regular))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(timeLabel)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibleLabel)
    }

    private var timeLabel: String {
        guard let tz = TimeZone(identifier: item.tz) else { return "" }
        return "\(SnapshotTimeFormatting.timeString(item.startsAt, in: tz)) \(SnapshotTimeFormatting.zoneLabel(for: tz, at: item.startsAt))"
    }

    private var accessibleLabel: String {
        var parts: [String] = []
        if isNext { parts.append("Next up") }
        parts.append(item.category.displayName)
        parts.append(item.title)
        if !timeLabel.isEmpty { parts.append(timeLabel) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Category presentation

/// Icon/label/color mapping itself now lives in `Platform/Shared
/// /CategoryPresentation.swift` (DRY M1 #3), shared with the app's
/// `ItemCategory` — this tile just consumes it.
private struct SnapshotCategoryTile: View {
    let category: SnapshotItem.Category
    var side: CGFloat = 30

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.29, style: .continuous)
            .fill(category.colorPair.soft)
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: category.symbolName)
                    .font(.system(size: side * 0.47, weight: .medium))
                    .foregroundStyle(category.colorPair.fg)
            }
    }
}
