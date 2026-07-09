import SwiftUI

enum HeroCollapse {
    /// Points of upward scroll over which the hero goes fully expanded -> compact.
    static let collapseDistance: CGFloat = 120
    /// Reduced-motion snap point: past this, jump straight to compact.
    static let snapThreshold: CGFloat = 24
    /// Shared coordinate-space name every tab's ScrollView registers.
    static let scrollSpace = "tripHeroScroll"

    /// offset: positive = content scrolled up (hero should collapse). 0/negative
    /// (rubber-band at top) = fully expanded. Result clamped 0...1.
    static func progress(for offset: CGFloat, reduceMotion: Bool) -> Double {
        if reduceMotion { return offset > snapThreshold ? 1 : 0 }
        guard offset > 0 else { return 0 }
        return Double(min(offset / collapseDistance, 1))
    }
}

/// Set by each tab's ScrollView sentinel; read per-tab in TripView.tabContent.
struct HeroScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Zero-height sentinel placed as the FIRST child inside a tab's scroll content.
/// Reports how far that content has scrolled up, in the shared coordinate space.
struct HeroScrollSentinel: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: HeroScrollOffsetKey.self,
                value: -geo.frame(in: .named(HeroCollapse.scrollSpace)).minY
            )
        }
        .frame(height: 0)
    }
}

/// Owns the per-tab scroll offsets that drive the hero's collapse. A
/// reference type (`@Observable`), not a value held in `TripView`'s own
/// `@State`, is deliberate: `TripView` creates one instance and hands it to
/// `TripHeroView`, but never itself reads `offsets` — Swift's Observation
/// framework only invalidates a view whose `body` actually accesses a
/// changed property, so `tabContent(_:content:)`'s per-scroll-frame
/// `.onPreferenceChange` write (still attached inside `TripView`, since
/// that's the only place that sees all three tabs' sentinels) lands here
/// without re-invalidating `TripView.body` and its O(n) computed
/// itinerary/assignee inputs. Only `TripHeroView`, which reads
/// `offsets[selectedTab]` in `progress`, re-renders per frame. Fixes the
/// review finding on commit 3e58efc ("Collapse trip hero header on scroll
/// across all three tabs").
@Observable
final class HeroScrollModel {
    /// Per-tab raw scroll offset (`HeroScrollSentinel`'s reported value),
    /// keyed so switching tabs doesn't blend one tab's scroll position into
    /// another's hero collapse state.
    var offsets: [TripView.Tab: CGFloat] = [:]

    func progress(for tab: TripView.Tab, reduceMotion: Bool) -> Double {
        HeroCollapse.progress(for: offsets[tab] ?? 0, reduceMotion: reduceMotion)
    }
}

/// The trip hero (§4.2: gradient, glass back/share, city, meta) — extracted
/// from `TripView` into its own `View` so the scroll-driven collapse only
/// re-renders this small subtree, not the whole trip screen (see
/// `HeroScrollModel`'s doc comment for why). `TripView` still owns
/// everything else (selected tab, edit-sheet presentation, role gating);
/// this view is handed just what it needs to render and to trigger the
/// edit sheet / share route / back navigation.
struct TripHeroView: View {
    let trip: Trip
    let tripProfileCount: Int
    let selectedTab: TripView.Tab
    let reduceMotion: Bool
    let dynamicTypeSize: DynamicTypeSize
    let canEditTrip: Bool
    @Binding var isEditingTrip: Bool
    let model: HeroScrollModel

    @Environment(\.dismiss) private var dismiss

    private var progress: Double {
        model.progress(for: selectedTab, reduceMotion: reduceMotion)
    }

    var body: some View {
        let p = progress
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                GlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                    dismiss()
                }
                Spacer()
                // Discoverable organizer edit entry point (finding 4): the
                // Home context menu's "Edit trip" is a shortcut, not the
                // sole route (HIG). Gated on the same `myRole` the FAB uses.
                if canEditTrip {
                    GlassCircleButton(systemImage: "pencil", accessibilityLabel: "Edit trip") {
                        isEditingTrip = true
                    }
                }
                // A `NavigationLink(value:)`, not a `GlassCircleButton`
                // action closure: `TripView` doesn't own the shared
                // `NavigationPath` (`HomeView` does), but a value-based
                // link pushes onto the nearest enclosing `NavigationStack`
                // regardless of nesting depth — same mechanism
                // `BookingsTabView`/`TimelineRowViews` already use for
                // `ItemRoute`. See `HomeView`'s `.navigationDestination(for:
                // ShareRoute.self)`.
                NavigationLink(value: ShareRoute(tripId: trip.id)) {
                    GlassCircleGlyph(systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Share trip")
            }

            Spacer(minLength: Spacing.sm)

            Text(trip.title)
                .font(Typo.display(Typo.Size.display - 10 * p))
                .foregroundStyle(.white)
                // Nit from the collapse review: only clamp to one line once
                // fully collapsed (`p >= 1`, hit at the reduce-motion snap
                // threshold too), instead of switching mid-scroll at `p >
                // 0.5` — that hard switch visibly reflowed the title while
                // scrolling with reduce-motion off.
                .lineLimit(p >= 1 ? 1 : 2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            // Finding 2 of the collapse risk review: at accessibility
            // Dynamic Type sizes, skip the fixed-height collapse (it can
            // clip multi-line meta text mid-fade) and just fade via opacity.
            if dynamicTypeSize.isAccessibilitySize {
                metaRow
                    .padding(.top, Spacing.xs * (1 - p))
                    .opacity(1 - min(1, p * 1.6))
            } else {
                metaRow
                    .padding(.top, Spacing.xs * (1 - p))
                    .opacity(1 - min(1, p * 1.6))
                    .frame(height: 22 * (1 - p), alignment: .top)
                    .clipped()
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.sm + (Spacing.lg - Spacing.sm) * (1 - p))
        // Finding 2: `minHeight` (not a fixed `height`) so the hero grows
        // instead of clipping when Dynamic Type scales the title/meta —
        // the gradient background and scrim below are `.background`/
        // `.overlay`, so they scale with it for free. The `150 - 54 * p`
        // term is the scroll-collapse range added on top of that: fully
        // expanded at `p == 0`, compact (96pt floor — clears the notch +
        // 44pt button row) at `p == 1`.
        .frame(minHeight: 150 - 54 * p, alignment: .bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            CoverGradient.from(key: trip.coverGradient)
                // Finding 3: swapped the flat 8%-black scrim for the same
                // bottom-anchored `textScrim` `TripCard` uses for the
                // identical white-text-on-gradient problem (clear until 35%
                // down, ramping to 45%-black at the bottom — see
                // `PaletteExtras.swift`). The hero's title/meta sit
                // bottom-anchored in the densest band: the meta row at
                // ~85% depth composites to ~4.5-5:1, the 30pt display title
                // at ~70% depth to ~4+:1 — clearing AA's 4.5:1 and 3:1
                // large-text bars respectively on all three gradients' worst
                // corners. The top-row glyph buttons no longer need this
                // scrim now that their own fill is `coverPillFill`.
                .overlay(CoverGradient.textScrim)
                .ignoresSafeArea(edges: .top)
        }
    }

    /// Finding 4 + 9b: two VoiceOver-distinct pieces instead of one run-on
    /// row of literal "·" fragments — dates/duration read as a single
    /// sentence, and the traveler count is a real tappable route (not just
    /// decorative text) to `ShareRoute`'s "who's coming" screen.
    private var metaRow: some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text(dateRangeText)
                metaDot
                Text("\(trip.durationInDays()) day\(trip.durationInDays() == 1 ? "" : "s")")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(accessibleDateRangeText), \(trip.durationInDays()) day\(trip.durationInDays() == 1 ? "" : "s")"
            )

            metaDot

            NavigationLink(value: ShareRoute(tripId: trip.id)) {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "person.2.fill").font(.system(size: 10))
                    Text("\(max(tripProfileCount, 1))")
                    // Finding 5: a small tappability cue for sighted users —
                    // VoiceOver already gets the same signal from the
                    // `.accessibilityHint` below, so this glyph adds nothing
                    // there and is hidden from it.
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(Palette.coverPillFill, in: Capsule())
                // Finding 4: the visual capsule (a `.background`, so it
                // doesn't grow with the frame) was rendering under 44pt
                // wide — `minWidth` added alongside the existing
                // `minHeight` so the hit target meets the 44pt floor on
                // both axes; `.contentShape(Rectangle())` below already
                // extends hit-testing to the enlarged frame, which only
                // borders non-interactive text.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(max(tripProfileCount, 1)) traveler\(max(tripProfileCount, 1) == 1 ? "" : "s")")
            .accessibilityHint("Manage people and invites")
        }
        .font(Typo.body(Typo.Size.caption))
        .foregroundStyle(.white.opacity(0.92))
    }

    private var metaDot: some View {
        Text("·").opacity(0.6)
            .accessibilityHidden(true)
    }

    /// Finding 5: delegates to `TripDateRangeFormat` so a trip outside the
    /// current year (or spanning two) shows a year instead of the old
    /// always-year-less "Mar 14 – Mar 20."
    private var dateRangeText: String {
        TripDateRangeFormat.text(start: trip.startDate, end: trip.endDate)
    }

    /// Same rules as `dateRangeText`, joined with a spoken "to" instead of
    /// the visual en-dash — VoiceOver reads punctuation like "–" and "·"
    /// as literal fragments, not implied connectors (finding 9b).
    private var accessibleDateRangeText: String {
        TripDateRangeFormat.spokenText(start: trip.startDate, end: trip.endDate)
    }
}
