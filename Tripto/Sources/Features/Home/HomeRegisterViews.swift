import SwiftUI

/// SwiftUI components for Home's "next"/"now"/"been" registers
/// (docs/UX_REDESIGN_ROADMAP.md Phase 5). Pure renderers over the value
/// models in `HomeRegisters.swift` — same "model file / view file" split as
/// `TimelineModels.swift` / `TimelineRowViews.swift` (Features/Trip).

/// P5.2: the countdown ring drawn around the "next" register's "in N days"
/// pill bullet. `fraction` is pre-clamped by the caller (`TripCard`).
/// Decorative — the pill's own "in N days" text already carries the
/// meaning, so this stays out of VoiceOver.
struct CountdownRing: View {
    let fraction: Double
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 13

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.28), lineWidth: 2.4)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Palette.amber, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                // Starts at 12 o'clock, draws clockwise — the familiar
                // activity-ring reading direction.
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter, height: diameter)
        .accessibilityHidden(true)
    }
}

/// P5.3: the live-trip pill's leading dot (mockup's `.live-dot`) — a small
/// glow standing in for the CSS `box-shadow` halo. Decorative, same reason
/// as `CountdownRing` above.
struct LiveDot: View {
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 8

    var body: some View {
        Circle()
            .fill(Palette.amber)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle()
                    .stroke(Palette.amber.opacity(0.32), lineWidth: diameter * 0.4)
                    .scaleEffect(1.7)
            }
            .accessibilityHidden(true)
    }
}

/// P5.2: "FIRST UP · JL901 · HND → OKA · Wed 09:40" — the "next" register's
/// strip, glass-pill treatment matching `TripCard`'s existing status pill
/// (`Palette.coverPillFill`, already audited for white text on all three
/// cover gradients — see that token's own doc comment). The whole card is
/// one VoiceOver stop (`TripCard.accessibilityLabel`), so this stays out of
/// the accessibility tree.
struct FirstUpStrip: View {
    let model: HomeFirstUp

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var iconSize: CGFloat = 14

    /// Same `AnyLayout` swap as `TripCard.topLayout` — an `HStack` here has
    /// no room for the icon, the two-line label, and the trailing
    /// weekday/time block at accessibility sizes, so this stacks them
    /// leading-aligned instead.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xxs))
            : AnyLayout(HStackLayout(spacing: Spacing.sm))
    }

    var body: some View {
        layout {
            Image(systemName: model.systemImage)
                .font(.system(size: iconSize, weight: .semibold))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("First up")
                    .font(Typo.body(9.5, weight: .bold))
                    .tracking(1.1)
                    .textCase(.uppercase)
                    .opacity(0.85)
                Text(model.text)
                    .font(Typo.body(13, weight: .semibold))
                    .lineLimit(1)
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: Spacing.sm)
            }
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 0) {
                Text(model.weekday)
                Text(model.time).monospacedDigit()
            }
            .font(Typo.body(11.5, weight: .semibold))
            .opacity(0.85)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .background(Palette.coverPillFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }
}

/// P5.3: the live trip's thin day-progress bar — one segment per trip day,
/// colored done/now/upcoming. Purely decorative reinforcement of the "Day N
/// of M" pill text, which already carries the same information accessibly
/// (§7.3: color/position is never the only signal).
struct DayProgressBar: View {
    let dayNumber: Int
    let totalDays: Int

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(1...max(totalDays, 1), id: \.self) { day in
                Capsule()
                    .fill(segmentColor(for: day))
                    .frame(height: 3)
            }
        }
        .accessibilityHidden(true)
    }

    private func segmentColor(for day: Int) -> Color {
        if day < dayNumber { return Palette.amber.opacity(0.55) }
        if day == dayNumber { return .white }
        return .white.opacity(0.22)
    }
}

/// P5.3: the "now" register's inline "Today · Thu 24 Jul" mini-list — same
/// glass-pill chrome as `FirstUpStrip`. Decorative to VoiceOver (see that
/// view's doc comment); `TripCard.accessibilityLabel` speaks today's plan
/// as part of the card's one combined sentence.
struct TodayPanelView: View {
    let panel: HomeTodayPanel

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text("Today \u{00B7} \(panel.dateText)")
                .font(Typo.body(9.5, weight: .bold))
                .tracking(1.1)
                .textCase(.uppercase)
                .opacity(0.85)
                .padding(.top, Spacing.xxs)

            ForEach(Array(panel.rows.enumerated()), id: \.offset) { _, row in
                rowView(row)
            }
            if panel.moreCount > 0 {
                Text("+ \(panel.moreCount) more today")
                    .font(Typo.body(11.5))
                    .opacity(0.7)
                    // Aligns under the row titles (past the time column) at
                    // default sizes; at accessibility sizes `rowView` below
                    // already stacks time above title, so there's no time
                    // column left to align past.
                    .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 52)
                    .padding(.top, 2)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Palette.coverPillFill, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityHidden(true)
    }

    /// Finding-shaped `isAccessibilitySize` branch, same reasoning as
    /// `FirstUpStrip.layout`: a fixed 40pt time column has no room to
    /// coexist with an AX-scaled title on one row.
    @ViewBuilder
    private func rowView(_ row: HomeTodayPanel.Row) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 1) {
                Text(row.time).font(Typo.body(12, weight: .bold)).monospacedDigit().opacity(0.7)
                Text(row.title).font(Typo.body(13, weight: .semibold))
            }
            .padding(.vertical, Spacing.xxs)
        } else {
            HStack(spacing: Spacing.sm) {
                Text(row.time)
                    .font(Typo.body(12, weight: .bold))
                    .monospacedDigit()
                    .opacity(0.7)
                    .frame(width: 40, alignment: .leading)
                Text(row.title)
                    .font(Typo.body(13, weight: .semibold))
                    .lineLimit(1)
            }
        }
    }
}

/// P5.4: "been" register row — muted, no gradient hero/avatars/countdown,
/// per the roadmap's "without this discipline a 2019 trip shouts as loudly
/// as the live one." `HomeView` wraps this in the tap `Button` (mirrors
/// `TripCard`'s own convention — this stays a plain presentational
/// component).
struct BeenRow: View {
    let trip: Trip
    let itemCount: Int

    var body: some View {
        HStack(spacing: Spacing.md) {
            // `.saturation`/`.opacity` are the direct SwiftUI equivalents of
            // the mockup's `filter: saturate(.5); opacity: .92` — no cover
            // gradient work needed, just muting the same token-driven
            // gradient every other register already uses.
            CoverGradient.from(key: trip.coverGradient)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .saturation(0.5)
                .opacity(0.92)

            VStack(alignment: .leading, spacing: 2) {
                Text(trip.title)
                    .font(Typo.body(14.5, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                // `Palette.ink`/`Palette.slate` on `Palette.paper` — this
                // app's most-used text pairing (e.g. `HomeView.greetingBlock`),
                // already well clear of AA; no new contrast math needed.
                Text(HomeBeenSummary.subtitleText(trip: trip, itemCount: itemCount))
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Spacing.sm)
        .padding(.horizontal, Spacing.xl)
        .contentShape(Rectangle())
        // One VoiceOver stop per row, mirroring `TripCard`'s own
        // `.accessibilityElement(children: .ignore)` convention.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(trip.title), \(HomeBeenSummary.subtitleText(trip: trip, itemCount: itemCount))")
    }
}
