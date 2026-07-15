import SwiftUI

/// SwiftUI components for Home's "next"/"now"/"been" registers
/// (docs/UX_REDESIGN_ROADMAP.md Phase 5). Pure renderers over the value
/// models in `HomeRegisters.swift` — same "model file / view file" split as
/// `TimelineModels.swift` / `TimelineRowViews.swift` (Features/Trip).

/// P5.2: the countdown ring drawn around the "next" register's "in N days"
/// pill bullet. `fraction` is pre-clamped by the caller (`TripCard`).
/// Decorative — the pill's own "in N days" text already carries the
/// meaning, so this stays out of VoiceOver.
///
/// Reviewer finding: the original 2.4pt stroke on a 13pt circle (a ~0.18
/// diameter ratio) was too thin to read at a glance against the pill's own
/// busy gradient backdrop — confirmed by cropping/zooming a captured
/// screenshot, where the amber arc was technically present but easy to miss
/// entirely. The mockup's own `.ring` is a thicker donut (13px circle, 3px
/// inset — a ~0.27 ratio); `lineWidth` now matches that proportion, and the
/// track's own opacity is bumped so the UNFILLED portion also reads clearly
/// rather than blending into `coverPillFill`.
struct CountdownRing: View {
    let fraction: Double
    @ScaledMetric(relativeTo: .caption) private var diameter: CGFloat = 14
    private var lineWidth: CGFloat { diameter * 0.27 }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.4), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(Palette.amber, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
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
                    .foregroundStyle(Palette.coverPillAmberText)
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

    /// Reviewer nit: capped at the same ceiling `ItineraryDayBucketing
    /// .maxGapFillDays` already uses for its own "don't walk a corrupt/
    /// absurd date range's full length" guard — an un-capped `totalDays`
    /// (a manual edit or a bad import) would otherwise draw one segment per
    /// day with no upper bound.
    private var segmentCount: Int {
        min(max(totalDays, 1), ItineraryDayBucketing.maxGapFillDays)
    }

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            ForEach(1...segmentCount, id: \.self) { day in
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
                .foregroundStyle(Palette.coverPillAmberText)
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

/// P6.2 (docs/UX_REDESIGN_ROADMAP.md): the duplicate-trip strip — Home
/// phone 1 note 3's fused "Same dates as the trip above" + Merge. `HomeView`
/// renders this as its own adjacent `List` row directly below the SECOND
/// card of a detected duplicate pair (`TripMergeDetection.survivorByShellId`)
/// — not fused inside `TripCard` itself (that file is off this phase's
/// surface list), so the "fusion" is approximated with tightened spacing
/// between the two rows rather than shared/matched corner radii. ponytail:
/// a pixel-perfect flush card+strip (matching the mockup's shared rounded-
/// rect silhouette) would need `TripCard`'s own corner treatment to
/// coordinate with this row; revisit if the plain rounded-card-below-card
/// look reads as two unrelated elements in the ux-expert pass.
struct DuplicateTripStrip: View {
    /// The survivor card's title — folded into the "Merge" button's own
    /// accessibility label (see below) so the action still names its
    /// target if VoiceOver's rotor jumps here directly, out of context.
    let survivorTitle: String
    /// D6 (reviewer, MED — silent dead button): true while ANY merge is
    /// already pending anywhere on Home (this strip's own, or a different
    /// pair's) — `HomeView` passes `mergeCountdown != nil` unconditionally
    /// to every strip. Dims + disables "Merge" rather than leaving a second
    /// tap silently swallowed with no visible feedback.
    var isMergePending = false
    let onMerge: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Same `AnyLayout` swap as `FirstUpStrip.layout`/`TripCard.topLayout`
    /// — the label and the "Merge" button have no room to sit side by side
    /// at accessibility Dynamic Type sizes.
    private var layout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.sm))
    }

    var body: some View {
        layout {
            HStack(alignment: .top, spacing: Spacing.sm) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Palette.amberInk)
                    .padding(.top, 1)
                    .accessibilityHidden(true)
                Text("Same dates as the trip above")
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
            // Combine only the informational icon+text pair into one
            // VoiceOver stop — same "combine only the informational
            // subtree" rule `ItineraryTabView.conflictBanner`'s own doc
            // comment states; "Merge" below stays its own, separately
            // reachable control. Combining a `Button` into a `.combine`d
            // parent would swallow its distinct tap/rotor target, the exact
            // regression this split avoids.
            .accessibilityElement(children: .combine)
            // `Spacer` is HStack-only (same reasoning as `TripCard
            // .topLayout`'s identical guard) — inside the VStack variant it
            // would expand vertically and blow out this row's height.
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: Spacing.sm)
            }
            // Ink-filled compact pill — the exact recipe `ItineraryTabView
            // .conflictBanner`'s "Review stays" already established for
            // this app's "heads up + a recourse" banner shape (P2.1):
            // `Palette.paper` on `Palette.ink` measures ~16.2:1 light /
            // ~16.1:1 dark (independently computed from `Tokens.swift`'s
            // hex values), reused rather than re-derived.
            Button("Merge", action: onMerge)
                .font(Typo.body(13, weight: .semibold))
                .foregroundStyle(Palette.paper)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(Palette.ink, in: Capsule())
                .frame(minHeight: 44)
                .contentShape(Capsule())
                .buttonStyle(.plain)
                .accessibilityLabel("Merge into \(survivorTitle)")
                // D6: `.disabled()` alone doesn't dim a manually-styled
                // `.plain`-button label (`ShareTripView.roleBadgeLabel`'s own
                // finding-5 doc comment) — both together, so a blocked tap
                // reads as blocked rather than silently doing nothing.
                .opacity(isMergePending ? 0.5 : 1)
                .disabled(isMergePending)
        }
        .padding(Spacing.md)
        // `Palette.ink` on `Palette.amberSoft` (the text above) measures
        // ~14.4:1 light / ~10.9:1 dark — same already-audited pairing as
        // `SettingsView.conversionPromptFeatureCard`/`ItineraryTabView
        // .conflictBanner`, reused unchanged.
        .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                .stroke(Palette.amber.opacity(0.3), lineWidth: 1)
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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: Spacing.md) {
            // `.saturation`/`.opacity` are the direct SwiftUI equivalents of
            // the mockup's `filter: saturate(.5); opacity: .92` — P7b craft
            // audit: at `.5` every cover read as near-identical muted navy
            // (each gradient's own accent hue drowned out, especially since
            // all three curated gradients — and every generated one —
            // already share one fixed dark-indigo third stop,
            // `CoverGradientGenerator`'s own doc comment). Bumped to `.75` so
            // each thumb keeps a real hint of its own cover's hue; still
            // well below a live card's full `1.0` (no `.saturation` at all
            // in `TripCard`) and paired with the same `.opacity(0.92)`, so
            // "been" thumbnails still visibly recede vs. an "ahead" card —
            // register discipline (the roadmap's own "a 2019 trip shouldn't
            // shout as loudly as the live one," this type's own doc comment)
            // isn't just preserved by opacity/scale alone.
            CoverGradient.from(key: trip.coverGradient)
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .saturation(0.75)
                .opacity(0.92)

            VStack(alignment: .leading, spacing: 2) {
                // P7b craft-audit fix: hard-truncated at 1 line even at AX3
                // (`home-been-light-ax3.png`) — 2 lines at accessibility
                // sizes only, same `isAccessibilitySize` convention as
                // `TripCard.title`/`FirstUpStrip.layout`; default size stays
                // 1 line (this is a quiet, compact archive row, not a
                // register card).
                Text(trip.title)
                    .font(Typo.body(14.5, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
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

/// UX P6.5: the collapsed "been" register when `SettingsView`'s "Show past
/// trips" toggle is off — replaces the whole sticky-year-headers archive
/// with one quiet row, so hiding past trips never reads as data loss (the
/// count is always right there, one tap un-hides them). `HomeView` only
/// ever shows this when there's at least one past trip to hide
/// (`HomePastTripsVisibility.shouldShowHiddenRow`) — an empty archive has
/// nothing to collapse, same as the expanded case's own empty-`beenTrips`
/// gate.
struct HiddenPastTripsRow: View {
    let count: Int
    let onShow: () -> Void

    var body: some View {
        Button(action: onShow) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                    .accessibilityHidden(true)
                Text(HomePastTripsVisibility.hiddenRowText(beenCount: count))
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                Spacer(minLength: Spacing.sm)
                // `Palette.amberInk` — this app's existing "inline (non-
                // capsule) amber text action" token (`PaletteExtras.swift`'s
                // own doc comment), reused rather than a new color.
                Text("Show")
                    .font(Typo.body(Typo.Size.caption, weight: .bold))
                    .foregroundStyle(Palette.amberInk)
            }
            .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.xl)
        // One VoiceOver stop, count + action together (P6.5 brief) —
        // same "combine into one spoken sentence" convention as `BeenRow`
        // above.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(HomePastTripsVisibility.hiddenRowText(beenCount: count)), Show")
    }
}
