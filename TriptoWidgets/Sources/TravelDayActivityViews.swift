import ActivityKit
import SwiftUI
import WidgetKit

/// The travel-day Live Activity's Lock Screen + Dynamic Island presentation
/// (PLAN-signature-layer.md §D6). `LiveActivityCoordinator` (app-side)
/// starts this exactly once per flight and never calls `.update()` again —
/// every view below must be a pure function of `(attributes, state)` at the
/// moment it's composed, since `Text(timerInterval:)` is the only thing
/// that keeps changing after that (research §1: zero pushes, zero further
/// app updates).
struct TravelDayActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TravelDayAttributes.self) { context in
            TravelDayLockScreenView(context: context)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TravelDayExpandedLeading(attributes: context.attributes)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TravelDayCountdown(departsAt: context.state.departsAt, font: .title2)
                        .accessibilityLabel(Text("Time until departure"))
                }
                DynamicIslandExpandedRegion(.center) {
                    TravelDayExpandedCenter(attributes: context.attributes, departsAt: context.state.departsAt)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let title = TravelDaySnapshotLookup.tripTitle(for: context.attributes.tripId) {
                        Text(title)
                            .font(Typo.body(Typo.Size.caption, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
                    }
                }
            } compactLeading: {
                Image(systemName: "airplane")
                    .foregroundStyle(Palette.amber)
                    .accessibilityHidden(true)
            } compactTrailing: {
                TravelDayCountdown(departsAt: context.state.departsAt, font: .caption2)
                    .accessibilityLabel(Text("Time until departure"))
            } minimal: {
                TravelDayCountdown(departsAt: context.state.departsAt, font: .caption2)
                    .accessibilityLabel(Text("Departure countdown"))
            }
            .widgetURL(URL(string: "tripto://trip/\(context.attributes.tripId.uuidString)"))
            .keylineTint(Palette.amber)
        }
    }
}

/// Countdown primitive shared by every region above — `Text(timerInterval:)`
/// is the one thing that keeps ticking with zero further app updates
/// (research §1); everything else in this file is static text set once at
/// start. Guards the range itself: once `departsAt` has passed, a
/// `ClosedRange(now...departsAt)` would be invalid (`lowerBound >
/// upperBound`, a crash) if this view were ever recomposed after departure
/// (e.g. the system relaunching the extension to redraw the last-known
/// state) — falls back to a static "0:00", matching §D6's documented
/// post-departure ceiling ("reads 0:00 until stale") instead of risking
/// that crash.
struct TravelDayCountdown: View {
    let departsAt: Date
    var font: Font = .body

    var body: some View {
        let now = Date.now
        Group {
            if now < departsAt {
                Text(timerInterval: now...departsAt, countsDown: true)
            } else {
                Text("0:00")
            }
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(.white)
    }
}

private struct TravelDayExpandedLeading: View {
    let attributes: TravelDayAttributes

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Image(systemName: "airplane")
                .foregroundStyle(Palette.amber)
            Text(attributes.flightName)
                .font(Typo.body(Typo.Size.body, weight: .semibold))
                .foregroundStyle(.white)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }
}

private struct TravelDayExpandedCenter: View {
    let attributes: TravelDayAttributes
    let departsAt: Date

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(attributes.routeText)
                .font(Typo.body(Typo.Size.body))
                .foregroundStyle(.white)
            Text("Departs \(departsText)")
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(.white.opacity(0.7))
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    /// §7.4: a flight's own departure time renders in its own zone, not
    /// device-local — looked up from the snapshot by item id since
    /// `TravelDayAttributes` itself carries no tz (frozen W2-A contract:
    /// `tripId, itemId, flightName, routeText` only — flagged as a gap in
    /// W2-B.md). Falls back to device-local formatting if the item has
    /// since aged out of the snapshot — the countdown itself never depends
    /// on this lookup, so a miss only costs this one caption, never
    /// correctness.
    private var departsText: String {
        let tz = TravelDaySnapshotLookup.timeZone(for: attributes.itemId) ?? .current
        return SnapshotTimeFormatting.timeString(departsAt, in: tz)
    }
}

struct TravelDayLockScreenView: View {
    let context: ActivityViewContext<TravelDayAttributes>

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            CoverGradient.dusk
            CoverGradient.textScrim
            HStack(alignment: .bottom, spacing: Spacing.md) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "airplane").foregroundStyle(.white)
                        Text(context.attributes.flightName)
                            .font(Typo.display(Typo.Size.title))
                            .foregroundStyle(.white)
                    }
                    Text(context.attributes.routeText)
                        .font(Typo.body(Typo.Size.body))
                        .foregroundStyle(.white.opacity(0.85))
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: Spacing.sm)
                TravelDayCountdown(departsAt: context.state.departsAt, font: Typo.display(Typo.Size.display))
                    .accessibilityLabel(Text("Time until departure"))
            }
            .padding(Spacing.lg)
            .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        }
    }
}

/// Display context `TravelDayAttributes` itself doesn't carry (frozen W2-A
/// contract — `tripId, itemId, flightName, routeText` only) — reads the
/// same App Group snapshot every other glanceable surface reads rather
/// than adding a new data path. Best-effort: if the trip/item has since
/// fallen out of the snapshot mid-countdown, callers hide/fall back
/// instead of showing something wrong; the countdown itself is
/// `ContentState`-only and never depends on this.
enum TravelDaySnapshotLookup {
    static func tripTitle(for tripId: UUID) -> String? {
        TripSnapshot.load()?.trips.first { $0.id == tripId }?.title
    }

    static func timeZone(for itemId: UUID) -> TimeZone? {
        guard let identifier = TripSnapshot.load()?.focusTripItems.first(where: { $0.id == itemId })?.tz else {
            return nil
        }
        return TimeZone(identifier: identifier)
    }
}
