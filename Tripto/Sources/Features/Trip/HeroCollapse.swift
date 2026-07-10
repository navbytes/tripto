import SwiftUI

enum HeroCollapse {
    /// Points of upward scroll over which the hero goes fully expanded -> compact.
    static let collapseDistance: CGFloat = 120
    /// Reduced-motion snap point: past this, jump straight to compact.
    static let snapThreshold: CGFloat = 24
    /// Per-tab coordinate-space name. Each tab's ScrollView must register a
    /// *distinct* name here — `TripView` deliberately keeps all three tabs'
    /// ScrollViews mounted simultaneously (`.opacity`-based tab switching,
    /// so each tab keeps its own scroll position across switches; see
    /// `TripView.tabContent`'s doc comment). A single shared literal name
    /// across three concurrently-mounted `ScrollView`s made SwiftUI's named
    /// coordinate-space resolution ambiguous, so every tab's
    /// `GeometryReader.frame(in:)` resolved against the wrong ancestor and
    /// `HeroScrollModel.offsets` stayed pinned at `0` even while scrolling —
    /// root-caused via live instrumentation. Keying the name by tab gives
    /// each ScrollView its own unambiguous space.
    static func scrollSpace(for tab: TripView.Tab) -> String {
        "tripHeroScroll-\(tab.rawValue)"
    }

    /// offset: positive = content scrolled up (hero should collapse). 0/negative
    /// (rubber-band at top) = fully expanded. Result clamped 0...1.
    static func progress(for offset: CGFloat, reduceMotion: Bool) -> Double {
        if reduceMotion { return offset > snapThreshold ? 1 : 0 }
        guard offset > 0 else { return 0 }
        return Double(min(offset / collapseDistance, 1))
    }
}

/// Set by `TripHeroView`'s non-accessibility meta row; read there to size its
/// own collapse frame off the row's true natural (fully-expanded) height
/// instead of a stale hardcoded guess — see that call site's doc comment.
/// (Scroll-offset tracking itself no longer uses a `PreferenceKey` — see
/// `heroScrollTracking(tab:model:)`'s doc comment — but this one is
/// unrelated: a single, non-scroll-driven measurement inside `TripHeroView`
/// itself, where `PreferenceKey`'s usual "measure a descendant, read it in
/// an ancestor one hop up" shape is exactly what's needed and isn't affected
/// by the propagation gap described there.)
struct HeroMetaHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

extension View {
    /// Attaches hero-scroll-offset tracking to a tab's scroll content (its
    /// `LazyVStack`), writing straight into `model.offsets[tab]` on every
    /// layout pass. Deliberately *not* built on `PreferenceKey`/
    /// `.onPreferenceChange` (the standard recipe, and this file's own
    /// earlier approach) — live instrumentation root-caused a real gap in
    /// how this SwiftUI/OS combination delivers preference changes: a
    /// `.preference(key:value:)` set here was measured (via raw
    /// `GeometryReader`/`onGeometryChange` logging, bypassing
    /// `.onPreferenceChange` entirely) to update correctly and continuously
    /// as a tab scrolled, but `TripView.tabContent`'s
    /// `.onPreferenceChange(HeroScrollOffsetKey.self)` several modifier
    /// hops up never saw more than the initial mount value. Bisecting
    /// modifier-by-modifier isolated the exact break: `ItineraryTabView`'s
    /// `.overlay(alignment:) { if let todayTargetId { todayPill(...) } }` —
    /// an `.overlay` whose content is conditional on an `Optional` — silently
    /// swallows preference propagation for everything upstream of it once
    /// crossed, even though the overlay renders nothing (`todayTargetId ==
    /// nil`) for most of this trip's lifetime. That's a `PreferenceKey`-
    /// specific failure mode, not something a coordinate-space or
    /// measurement-placement fix (this file's other two fixes) can address,
    /// and not safe to route around by relocating one `.overlay` today only
    /// to hit the same class of bug from some future modifier in the same
    /// chain. Writing directly into the shared `HeroScrollModel` (a
    /// reference type every tab already has access to once threaded
    /// through) sidesteps `PreferenceKey` propagation for this path
    /// entirely instead.
    ///
    /// Uses `onGeometryChange(for:of:action:)` (iOS 18+) where available —
    /// confirmed via the same instrumentation to fire reliably on every
    /// layout pass, including ones driven by `ScrollViewReader.scrollTo`
    /// rather than a touch-driven pan — falling back to a
    /// `.background(GeometryReader{...})` read through `.onChange(of:)` (no
    /// `PreferenceKey` there either) on iOS 17, this app's actual
    /// deployment target.
    ///
    /// Apply this only inside the populated (non-empty-state) branch of a
    /// tab — an empty state must call `model.offsets[tab] = 0` itself (or
    /// simply never call this), so the hero stays expanded — and pair it
    /// with `.coordinateSpace(.named(HeroCollapse.scrollSpace(for: tab)))`
    /// on that tab's enclosing `ScrollView`.
    @ViewBuilder
    func heroScrollTracking(tab: TripView.Tab, model: HeroScrollModel) -> some View {
        if #available(iOS 18, *) {
            onGeometryChange(for: CGFloat.self) { geo in
                -geo.frame(in: .named(HeroCollapse.scrollSpace(for: tab))).minY
            } action: { newValue in
                model.offsets[tab] = newValue
            }
        } else {
            background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.frame(in: .named(HeroCollapse.scrollSpace(for: tab))).minY, initial: true) { _, minY in
                            model.offsets[tab] = -minY
                        }
                }
            )
        }
    }
}

/// Owns the per-tab scroll offsets that drive the hero's collapse. A
/// reference type (`@Observable`), not a value held in `TripView`'s own
/// `@State`, is deliberate: `TripView` creates one instance and hands it to
/// `TripHeroView` (to read) and to each of the three tab views (to write,
/// via `.heroScrollTracking(tab:model:)`) — Swift's Observation framework
/// only invalidates a view whose `body` actually accesses a changed
/// property, so a tab's per-scroll-frame write here lands without
/// re-invalidating `TripView.body` and its O(n) computed itinerary/assignee
/// inputs. Only `TripHeroView`, which reads `offsets[selectedTab]` in
/// `progress`, re-renders per frame. Fixes the review finding on commit
/// 3e58efc ("Collapse trip hero header on scroll across all three tabs").
@Observable
final class HeroScrollModel {
    /// Per-tab raw scroll offset (written directly by that tab's
    /// `.heroScrollTracking(tab:model:)`), keyed so switching tabs doesn't
    /// blend one tab's scroll position into another's hero collapse state.
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

    /// `metaRow`'s traveler-count icon, next to its own count text — see the
    /// shared `@ScaledMetric` recipe used throughout Features/Trip. The
    /// chevron beside it is already hidden from VoiceOver (decorative) but
    /// still visually scales for sighted low-vision users.
    @ScaledMetric(relativeTo: .body) private var travelerIconSize: CGFloat = 10
    @ScaledMetric(relativeTo: .body) private var travelerChevronSize: CGFloat = 9

    /// The meta row's true, fully-expanded natural height — measured (see
    /// `metaRow`'s `.background`/`.onPreferenceChange` below) rather than
    /// assumed, since the traveler-count pill's 44pt tap target (finding 4)
    /// makes the row taller than its text alone. 44 is only the sane
    /// first-frame fallback before the first measurement lands, chosen to
    /// match that pill's real height so the row is never clipped even on
    /// frame one.
    @State private var metaNaturalHeight: CGFloat = 44

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
                    // Measured BEFORE the `.frame(height:)` below clamps
                    // this view's size — `.background` sizes to fit its
                    // parent's layout here, so this `GeometryReader` reports
                    // the row's true natural height (including the
                    // traveler-count pill's 44pt tap target, finding 4).
                    // Measuring after the clamp would instead report the
                    // already-clamped size, which would self-reinforce down
                    // to 0 rather than the row's real height.
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(key: HeroMetaHeightKey.self, value: geo.size.height)
                        }
                    )
                    .onPreferenceChange(HeroMetaHeightKey.self) { height in
                        // Only trust a measurement taken while the row is
                        // fully expanded/unclamped (`p == 0`) — otherwise
                        // this would capture an already-clamped-smaller
                        // height mid-collapse and lock the row into it.
                        // `height > 0` additionally guards a real
                        // GeometryReader quirk verified on-device: its very
                        // first reported value inside a `.background` can
                        // land as a bogus `0` before the surrounding layout
                        // has settled — trusting that zero (even though
                        // `p == 0` at that moment too) would permanently
                        // latch the row's frame to 0pt, since every later
                        // render then multiplies that 0 by `(1 - p)`.
                        if p == 0, height > 0 { metaNaturalHeight = height }
                    }
                    // The row's real natural height includes the
                    // traveler-count pill's 44pt tap target (finding 4), not
                    // just its text line — a hardcoded `22` here clipped the
                    // row from the very first frame, even at rest (`p ==
                    // 0`). `metaNaturalHeight` (measured above) is used
                    // instead.
                    .frame(height: metaNaturalHeight * (1 - p), alignment: .top)
                    .clipped()
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.sm + (Spacing.lg - Spacing.sm) * (1 - p))
        // Without this, the top `Spacer(minLength:)` reports a flexible
        // (`.infinity`) max height, making this whole VStack greedy — it
        // then competes with its sibling tab-content ZStack in
        // `TripView.content(for:)` for all available vertical space instead
        // of sizing to its own content, so the `.frame(minHeight:)` floor
        // below never actually caps it. `fixedSize(vertical:)` collapses
        // the VStack to its ideal/intrinsic height first (the Spacer down
        // to its `minLength`, not `.infinity`), and the `minHeight` below
        // then floors *that* into the collapse range as intended. Ideal
        // height still grows with Dynamic Type (the title/meta measure
        // taller), so this stays compatible with the accessibility-size
        // handling above.
        .fixedSize(horizontal: false, vertical: true)
        // Finding 2: `minHeight` (not a fixed `height`) so the hero grows
        // instead of clipping when Dynamic Type scales the title/meta —
        // the gradient background and scrim below are `.background`/
        // `.overlay`, so they scale with it for free. The `150 - 54 * p`
        // term is the scroll-collapse range added on top of that: fully
        // expanded at `p == 0`, compact (96pt floor — clears the notch +
        // 44pt button row) at `p == 1`.
        //
        // D2 defect 3: `alignment: .bottom` here (kept for the default/
        // non-AX case — unaffected, verified pixel-identical) is what let
        // the button row render on top of the status bar at accessibility
        // sizes, on whichever tab is `TripView`'s *initial* `selectedTab`
        // (Itinerary) specifically — live-instrumented via three nested
        // `GeometryReader`s reading `.global` frames: this frame's own box
        // consistently settles at the correct safe-area-respecting origin
        // (confirmed identical on Itinerary vs Packing), but the button
        // row's *measured* position landed ~48pt above that box's own top
        // — almost exactly the gap between this view's first and second
        // layout pass's differing ideal heights (`.fixedSize` re-resolving
        // the AX-branch `metaRow`'s wrapped height once real width
        // settles). `alignment: .bottom` computes a child's position from
        // `frameHeight - contentHeight`, i.e. from *two* independently-
        // resolving measurements; when they disagree across passes (as
        // observed only on the tab mounted on the very first render, never
        // on a tab reached by a later state change), the button row is
        // placed as if inside a taller phantom box. `alignment: .top`
        // places content directly from the box's own top edge — one
        // measurement, not a difference of two — sidestepping the mismatch
        // regardless of its deeper cause. Safe to scope to `isAccessibilitySize`
        // only: `metaRow` never height-collapses there anyway (this file's
        // "Finding 2" above), so content already meets or exceeds
        // `minHeight` at every `p`, meaning there's rarely real slack for
        // `.bottom` vs `.top` to visibly disagree over even when the bug
        // isn't triggered — confirmed via the same instrumentation
        // (screenshot + logged global frames) before/after on both the
        // Itinerary and Packing tabs at AX5.
        .frame(minHeight: 150 - 54 * p, alignment: dynamicTypeSize.isAccessibilitySize ? .top : .bottom)
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
                    Image(systemName: "person.2.fill").font(.system(size: travelerIconSize))
                    Text("\(max(tripProfileCount, 1))")
                    // Finding 5: a small tappability cue for sighted users —
                    // VoiceOver already gets the same signal from the
                    // `.accessibilityHint` below, so this glyph adds nothing
                    // there and is hidden from it.
                    Image(systemName: "chevron.right")
                        .font(.system(size: travelerChevronSize))
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
