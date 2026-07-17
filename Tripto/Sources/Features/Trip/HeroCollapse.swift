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

    /// Reports this hero's own `.global` frame into `model.destFrame` --
    /// the flight overlay's convergence target
    /// (PLAN-signature-layer.md §D1 point 3). Gated to only write while a
    /// flight is actually in progress (`model.state != .idle`) so this
    /// costs nothing the rest of the hero's lifetime, and filtered through
    /// `HeroFlightGate.isPlausibleDestFrame` -- see that function's doc
    /// comment for the transient pre-layout report it exists to reject.
    /// Same iOS 17/18 dual `GeometryReader` recipe as
    /// `heroScrollTracking(tab:model:)` above, and, like it, deliberately
    /// not `PreferenceKey`-based -- see that extension's doc comment for
    /// the root-caused propagation gap this sidesteps.
    @ViewBuilder
    func heroFrameReporting(model: HeroFlightModel) -> some View {
        if #available(iOS 18, *) {
            onGeometryChange(for: CGRect.self) { geo in
                geo.frame(in: .global)
            } action: { newValue in
                guard model.state != .idle, HeroFlightGate.isPlausibleDestFrame(newValue) else { return }
                model.destFrame = newValue
            }
        } else {
            background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.frame(in: .global), initial: true) { _, frame in
                            guard model.state != .idle, HeroFlightGate.isPlausibleDestFrame(frame) else { return }
                            model.destFrame = frame
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
    /// E1 (docs/BACKLOG.md §E1): the overflow menu's one action, owned by
    /// `TripView` (it needs `items`/`toast`, neither of which this small
    /// hero subtree holds) — same "hand this view just the action closure
    /// it needs to trigger" shape as `isEditingTrip` above, just imperative
    /// instead of sheet-presenting.
    let onAddToCalendar: () -> Void
    let model: HeroScrollModel

    @Environment(\.dismiss) private var dismiss
    /// PLAN-signature-layer.md §D1: reachable via `.environment` from
    /// `HomeView`'s `NavigationStack` (an ancestor of every pushed
    /// destination, `TripView` included) -- same mechanism
    /// `AuthManager`/`SyncStatus` already rely on. Read/written only by
    /// `heroFrameReporting(model:)` below.
    @Environment(HeroFlightModel.self) private var heroFlight

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
    /// frame one. AX sizes never reach this path at all — see the
    /// `.frame(minHeight:)` call in `body` this feeds.
    @State private var metaNaturalHeight: CGFloat = 44

    private var progress: Double {
        model.progress(for: selectedTab, reduceMotion: reduceMotion)
    }

    var body: some View {
        let p = progress
        let hero = VStack(alignment: .leading, spacing: 0) {
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

                // E1 (docs/BACKLOG.md §E1): the trip's one overflow menu —
                // ungated (unlike the pencil above), matching the per-item
                // "Add to calendar" action row in `BookingDetailView`, which
                // is likewise available to any trip member, not just an
                // editor. Same glass-circle visual language as its sibling
                // buttons in this row; a `Menu` (not a bare button) so a
                // later second action has somewhere to land without another
                // entry-point redesign.
                Menu {
                    Button {
                        onAddToCalendar()
                    } label: {
                        Label("Add Trip to Calendar", systemImage: "calendar.badge.plus")
                    }
                } label: {
                    GlassCircleGlyph(systemImage: "ellipsis")
                }
                .accessibilityLabel("Trip actions")
            }

            Spacer(minLength: Spacing.sm)

            // docs/UX_REDESIGN_ROADMAP.md Phase 2 (P2.2): destination
            // context now lives in its own eyebrow line, above the title,
            // instead of the old parenthetical-in-the-title approach the
            // title's own `lineLimit` below used to have to make room for.
            // Same eyebrow recipe `TZShiftChipRow.eyebrow` already
            // established (Sofia Sans, 10pt bold, 0.8 tracking,
            // `.textCase(.uppercase)` rather than baking the uppercase into
            // the string itself, so VoiceOver still reads it as words, not
            // spelled out). Full white, not the meta row's dimmed
            // `.opacity(0.92)`: this eyebrow sits higher in the hero, where
            // `CoverGradient.textScrim` (PaletteExtras.swift) is thinner
            // than at the title/meta's own depth — full opacity keeps its
            // contrast headroom where the scrim gives it less help. Fades
            // with `metaRow` on collapse (same `1 - min(1, p * 1.6)` curve)
            // so a fully-collapsed hero shows just the compact title, as
            // before.
            Text(heroEyebrowText)
                .font(Typo.body(10, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(.white)
                // Same single-line-but-shrink-first safety net as the
                // title below: `destinationLabel` can be as long as a
                // user's own free-text destination, not just a short
                // country name.
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .opacity(1 - min(1, p * 1.6))
                // Reviewer N1: without this override VoiceOver reads the
                // full visual string, including "N days" — which `metaRow`
                // right below already speaks as part of its own
                // "{dates}, N days" label. Speaking just the destination
                // here also sidesteps the "·" itself being read as a
                // literal fragment (same reasoning `accessibleDateRangeText`
                // already documents for the meta row's en-dash).
                .accessibilityLabel(destinationLabel)

            Text(trip.title)
                .font(Typo.display(Typo.Size.display - 10 * p))
                .foregroundStyle(.white)
                // docs/UX_REDESIGN_ROADMAP.md Phase 2 (P2.2): "no two-line
                // wrap" — the eyebrow above now carries destination
                // context, so the title no longer needs the old `p >= 1 ?
                // 1 : 2` collapse-conditional (itself only there to avoid a
                // reflow-mid-scroll bug — see the collapse review nit this
                // replaces). Pinning to 1 line unconditionally removes that
                // whole class of bug rather than just avoiding it: there's
                // nothing left to reflow between.
                .lineLimit(1)
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
                    .background(measureMetaHeight)
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
        Group {
            // AX5 overlap fix, root cause (qa-evidence-s5 B /
            // J-itinerary / J-home / J-bookingdetail; live-isolated on
            // device with a bisected diagnostic build — colored placeholder
            // blocks swapped in for the title/metaRow one at a time to
            // strip out every red herring: not `NavigationLink`, not
            // `GeometryReader`/`PreferenceKey` measurement, not `Group`/`if`
            // branching, not the `Spacer` above): this `.frame(minHeight:)`
            // itself is what corrupts `.fixedSize(vertical: true)`'s ideal-
            // height probe above once total content exceeds the floor —
            // confirmed by removing only this one modifier from an
            // otherwise-untouched chain and watching previously-vanished
            // content (up to two full sibling rows' worth) reappear, with
            // the shortfall tracking almost exactly how much height the
            // *other* siblings ahead of the cut content occupy. Root cause
            // stops there (on-device bisection, not framework source); the
            // fix doesn't need to go further, because — per finding 2 above
            // and D2 defect 3's own note ("content already meets or exceeds
            // `minHeight` at every `p`") — this floor is dead weight at AX
            // sizes in the first place: `150 - 54 * p` tops out at 150,
            // title+metaRow alone clear that by hundreds of points once
            // Dynamic Type is scaled this far. Skipping the call outright
            // for `isAccessibilitySize` removes the one modifier that was
            // corrupting the probe without changing what it ever actually
            // constrained. Non-AX (`else`) is untouched — same modifier,
            // same value, same `.bottom` alignment as before.
            if dynamicTypeSize.isAccessibilitySize {
                hero
            } else {
                // Finding 2: `minHeight` (not a fixed `height`) so the hero
                // grows instead of clipping when Dynamic Type scales the
                // title/meta — the gradient background and scrim below are
                // `.background`/`.overlay`, so they scale with it for free.
                // The `150 - 54 * p` term is the scroll-collapse range added
                // on top of that: fully expanded at `p == 0`, compact (96pt
                // floor — clears the notch + 44pt button row) at `p == 1`.
                hero.frame(minHeight: 150 - 54 * p, alignment: .bottom)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            // UX "hero-immersive-profile" (Option B): a photo cover now
            // paints ONCE, behind {hero, banners, tab row} together
            // (`TripView.immersiveHeroSection`), clipped there so it can
            // never escape past the tab row's own bottom edge — the fix for
            // a pre-existing bug where this view's own `CoverImage` (the
            // photo branch specifically — a flat `CoverGradient`
            // `LinearGradient` never overflows its proposed frame the same
            // way a `scaledToFill` photo can) painted past the hero's own
            // bounds with nothing here ever clipping it. So: gradient-only
            // trips render exactly as before (untouched branch below);
            // photo trips keep ONLY `textScrim` here, still scoped to the
            // hero's own frame, so title/meta keep the exact same
            // protection as before — the photo itself, and its clip, now
            // live one level up.
            if trip.coverImagePath == nil {
                // P8b: `CoverImage` layers a photo (if `trip.coverImagePath` is
                // set) over the same `CoverGradient.from(key:)` this rendered
                // pre-P8b — the `textScrim` overlay right below is unchanged and
                // composites over whichever of the two actually shows through.
                CoverImage(coverGradientKey: trip.coverGradient, coverImagePath: trip.coverImagePath)
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
            } else {
                CoverGradient.textScrim
            }
        }
        // PLAN-signature-layer.md §D1 point 3: the flight's convergence
        // target. A no-op outside a flight (see the modifier's own doc
        // comment).
        .heroFrameReporting(model: heroFlight)
    }

    /// Finding 4 + 9b: the traveler count is a real tappable route (not
    /// just decorative text) to `ShareRoute`'s "who's coming" screen.
    ///
    /// ux-expert milestone M3: dropped the "· N days" this row used to
    /// append after the date range — the eyebrow above (`heroEyebrowText`)
    /// is now the one place duration lives; showing it twice in the same
    /// hero read as a straight duplicate ("May 14 – May 27 · 14 days" right
    /// under "PORTUGAL · 14 DAYS").
    ///
    /// AX5 overlap fix (qa-evidence-s5 B / J-itinerary / J-home): the
    /// default single HStack below squeezes the date text against
    /// `travelerPill` — at accessibility sizes a long/year-spanning date
    /// range can still be wider than the screen on its own, forcing two
    /// separate `Text`s to each independently decide where to wrap while
    /// sharing one HStack row's width, the exact "two Texts negotiating a
    /// squeezed row" shape `flightHeader`/`transportHeader`
    /// (BookingDetailView.swift) already document giving up on in favor of
    /// a vertical stack. This alone isn't the overlap's root cause (see
    /// the `.frame(minHeight:)` call this feeds, in `body`, for that) but
    /// it's real, independent fragility worth removing on its own terms:
    /// the AX branch here gives the traveler pill its own row instead of
    /// sharing one with the date text. Default rendering (the `else`
    /// branch) is untouched but for dropping duration.
    private var metaRow: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(dateRangeText)
                        .accessibilityLabel(accessibleDateRangeText)
                    travelerPill
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    Text(dateRangeText)
                        .accessibilityLabel(accessibleDateRangeText)
                    metaDot
                    travelerPill
                }
            }
        }
        .font(Typo.body(Typo.Size.caption))
        .foregroundStyle(.white.opacity(0.92))
    }

    private var travelerPill: some View {
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

    private var metaDot: some View {
        Text("·").opacity(0.6)
            .accessibilityHidden(true)
    }

    /// Shared by both `metaRow` measurement sites in `body` — see
    /// `metaNaturalHeight`'s doc comment for why `metaRow`'s real height is
    /// measured rather than trusted from `.fixedSize`'s own probe.
    private var measureMetaHeight: some View {
        GeometryReader { geo in
            Color.clear.preference(key: HeroMetaHeightKey.self, value: geo.size.height)
        }
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

    /// ux-expert milestone M3: no longer shown in `metaRow` (see that
    /// property's own doc comment) — kept only for `heroEyebrowText` below,
    /// the one place duration now lives.
    private var durationText: String {
        "\(trip.durationInDays()) day\(trip.durationInDays() == 1 ? "" : "s")"
    }

    /// docs/UX_REDESIGN_ROADMAP.md Phase 2 (P2.2): "{DESTINATION} · {N}
    /// DAYS" — reuses `durationText` above rather than re-deriving the same
    /// day count a second way.
    ///
    /// Reviewer N2: `destinationLabel` can still come back blank (an
    /// invalid/missing country code AND an empty `destination` field) —
    /// guarded here so that renders as a plain "N days" instead of a
    /// dangling "· N days" leading separator.
    private var heroEyebrowText: String {
        let destination = destinationLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty else { return durationText }
        return "\(destination) \u{00B7} \(durationText)"
    }

    /// `TripCard.locationText`'s own "localized country name, falling back
    /// to the raw destination string" rule (`Features/Home/TripCard.swift`)
    /// — reused rather than re-deriving a second country/destination label
    /// convention; this is exactly what already renders on Home's own trip
    /// cards. Falls back to `trip.destination` outright on the `nil` case
    /// (blank destination and no usable country code) so the eyebrow is
    /// never empty.
    private var destinationLabel: String {
        TripCard.locationText(countryCode: trip.countryCode, destination: trip.destination) ?? trip.destination
    }
}
