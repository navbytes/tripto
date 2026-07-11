import SwiftUI

/// Tunable constants for the card -> hero "flight" (PLAN-signature-layer.md
/// §D1). Mirrors `HeroCollapse`'s own small-namespace-of-constants shape.
enum HeroFlight {
    /// Approximate total settle time of the flight's position/size spring
    /// (`Motion.standard`) -- used only to *schedule* the clone's crossfade
    /// relative to flight start; the real end-of-flight (unblocking
    /// touches, resetting state) is driven by
    /// `withAnimation(...completionCriteria: .logicallyComplete)`'s own
    /// completion handler below, not this constant.
    static let duration: TimeInterval = 0.45
    /// How long the clone shows the card-only garnish (pills/avatars/meta)
    /// before it fades -- neither the flight nor the hero has anywhere for
    /// it to land (§D1 mechanism point 4).
    static let garnishFadeDuration: TimeInterval = 0.1
    /// Defensive cap on how long the overlay waits for `TripHeroView` to
    /// report `destFrame` before giving up and releasing the touch-block
    /// unanimated. Ponytail: the handshake should land within one layout
    /// pass per the plan's mechanism (the push is animation-disabled), but
    /// a permanently stuck full-screen touch-blocker is a worse failure
    /// than one unfinished flight, so this is the upgrade-free ceiling.
    static let destFrameTimeout: TimeInterval = 2
}

/// Per-trip-card `.global` frames, read only at tap time to seed a flight's
/// `sourceFrame`. Deliberately a plain (non-`@Observable`) class, and
/// deliberately not folded into `HeroFlightModel` below --
/// PLAN-signature-layer.md §D1 point 1 and HeroCollapse.swift's
/// `PreferenceKey` postmortem (`heroScrollTracking`'s doc comment) are why
/// this repo writes per-layout-pass geometry straight into a reference type
/// instead of `@Observable`/`PreferenceKey`: a write here must never
/// invalidate any view. Stale entries for scrolled-away or deleted trips
/// are never pruned (ponytail: dead bytes in a dictionary -- same call this
/// app already makes for `tornStub.*` keys, §D3) since every entry is only
/// ever read once, synchronously, at the tap that's about to navigate away.
final class CardFrameIndex {
    var frames: [UUID: CGRect] = [:]
}

/// Drives the card -> hero flight clone. Owned as `@State` in `HomeView`
/// and injected via `.environment` on its `NavigationStack` so
/// `TripHeroView` -- pushed underneath, arbitrarily deep in `TripView`'s
/// own subtree -- can read/write it across the navigation-stack boundary:
/// the same environment-cascades-through-`NavigationStack` mechanism
/// `AuthManager`/`SyncStatus` already rely on (injected above `HomeView`,
/// read straight from `TripView` today) to reach pushed destinations.
@Observable
@MainActor
final class HeroFlightModel {
    enum State: Equatable {
        case idle
        case flying(trip: Trip, people: [AvatarStack.Person], isPending: Bool, sourceFrame: CGRect)
    }

    var state: State = .idle
    /// The hero's `.global` frame once `TripHeroView` reports it (see
    /// `heroFrameReporting(model:)`, HeroCollapse.swift). `nil` until it
    /// lands, and reset alongside every flight so a stale value from a
    /// previous flight can never leak into the next one.
    var destFrame: CGRect?
}

/// Pure gate for whether a card tap should fly or fall back to a plain
/// push (PLAN-signature-layer.md §D1 point 7) -- split out for the same
/// reason as `HomeInitialTab.resolve`/`HomeEmptyPlaceholder.resolve`: the
/// decision table is unit-testable without a live view hierarchy.
enum HeroFlightGate {
    /// `hasSourceFrame` covers the (rare) case `CardFrameIndex` hasn't
    /// measured this card yet -- not called out explicitly in the plan's
    /// RM/AX bypass list, but a nil geometry read should fall back to a
    /// plain push rather than flying from a zero rect.
    static func shouldFly(reduceMotion: Bool, isAccessibilitySize: Bool, hasSourceFrame: Bool) -> Bool {
        !reduceMotion && !isAccessibilitySize && hasSourceFrame
    }

    /// Filters `TripHeroView`'s transient pre-layout frame report:
    /// `heroFrameReporting(model:)` (HeroCollapse.swift) can fire once with
    /// a frame centered near the view's pre-placement origin -- negative
    /// x/y, off-screen -- before settling on the real placed position one
    /// layout pass later (same class of multi-pass-`GeometryReader` issue
    /// this file's own `metaNaturalHeight` doc comment describes; verified
    /// live via a throwaway debug trace: first report `(-201, -437, 402,
    /// 151)`, second `(0, 62, 402, 151)`). A legitimately laid-out hero
    /// always starts at the screen's leading edge (`minX == 0`) at or below
    /// the safe area (`minY >= 0`), so this rejects the first and lets the
    /// real one through.
    static func isPlausibleDestFrame(_ frame: CGRect) -> Bool {
        frame.minX >= 0 && frame.minY >= 0 && frame.width > 0 && frame.height > 0
    }
}

extension View {
    /// Writes this trip card's `.global` frame into `index.frames[id]` on
    /// every layout pass -- read once at tap time to seed the flight. Same
    /// iOS 17/18 dual recipe as `heroScrollTracking(tab:model:)`
    /// (HeroCollapse.swift), and, like it, deliberately not
    /// `PreferenceKey`-based (see that extension's doc comment for the
    /// root-caused propagation gap this sidesteps).
    @ViewBuilder
    func cardFrameTracking(id: UUID, index: CardFrameIndex) -> some View {
        if #available(iOS 18, *) {
            onGeometryChange(for: CGRect.self) { geo in
                geo.frame(in: .global)
            } action: { newValue in
                index.frames[id] = newValue
            }
        } else {
            background(
                GeometryReader { geo in
                    Color.clear
                        .onChange(of: geo.frame(in: .global), initial: true) { _, frame in
                            index.frames[id] = frame
                        }
                }
            )
        }
    }
}

/// Hosted as an `.overlay` on `HomeView`'s `NavigationStack` (draws above
/// whatever's pushed underneath). Invisible and non-interactive whenever
/// idle; while `model.state == .flying` it owns the screen -- blocks
/// touches (§D1 point 5: identical feel to a system push, itself
/// non-interactive forward) and hosts the animating clone.
struct HeroFlightOverlay: View {
    let model: HeroFlightModel

    var body: some View {
        ZStack {
            Color.clear
            if case let .flying(trip, people, isPending, sourceFrame) = model.state {
                HeroFlightClone(trip: trip, people: people, isPending: isPending, sourceFrame: sourceFrame, model: model)
            }
        }
        .contentShape(Rectangle())
        .allowsHitTesting(model.state != .idle)
        .ignoresSafeArea()
    }
}

/// The animating clone. Gradient + scrim + title survive the whole flight
/// (§D1: the anatomy `TripCard`/`TripHeroView` already share -- both render
/// `CoverGradient.from(key:)` + `textScrim` + a bottom-leading white
/// `Typo.display(30)` title at the *same* font size in both end states, so
/// the title never needs to visually rescale, only the frame around it
/// does); the card-only garnish (status/pending pills, avatars, meta row)
/// fades out first, since neither the flight nor the hero has anywhere for
/// it to land. Only ever mounted at non-accessibility text sizes
/// (`HeroFlightGate` keeps `HomeView` from ever setting `model.state =
/// .flying` otherwise), so -- unlike `TripCard` itself -- this doesn't need
/// that view's AX-size `AnyLayout` branches; it mirrors `TripCard`'s plain
/// (non-AX) layout only.
private struct HeroFlightClone: View {
    let trip: Trip
    let people: [AvatarStack.Person]
    let isPending: Bool
    let sourceFrame: CGRect
    let model: HeroFlightModel

    @State private var frame: CGRect
    @State private var cornerRadius: CGFloat = Radii.cover
    @State private var garnishOpacity: Double = 1
    @State private var cloneOpacity: Double = 1
    @State private var hasStartedFlight = false
    @State private var didLand = false

    init(trip: Trip, people: [AvatarStack.Person], isPending: Bool, sourceFrame: CGRect, model: HeroFlightModel) {
        self.trip = trip
        self.people = people
        self.isPending = isPending
        self.sourceFrame = sourceFrame
        self.model = model
        _frame = State(initialValue: sourceFrame)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverGradient.from(key: trip.coverGradient)
            CoverGradient.textScrim

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    statusPill
                    if isPending {
                        glassPill(text: "Waiting to sync", icon: "clock")
                    }
                    Spacer(minLength: Spacing.sm)
                    AvatarStack(people: people)
                }
                .opacity(garnishOpacity)

                Spacer(minLength: Spacing.md)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(trip.title)
                        .font(Typo.display(Typo.Size.display))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    metaRow.opacity(garnishOpacity)
                }
            }
            .padding(Spacing.lg)
        }
        .frame(width: frame.width, height: frame.height)
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .position(x: frame.midX, y: frame.midY)
        .opacity(cloneOpacity)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task {
            beginGarnishFade()
            try? await Task.sleep(for: .seconds(HeroFlight.destFrameTimeout))
            if !hasStartedFlight {
                model.state = .idle
                model.destFrame = nil
            }
        }
        .onChange(of: model.destFrame) { _, newValue in
            guard let newValue else { return }
            beginFlight(to: newValue)
        }
        .sensoryFeedback(Haptics.settle, trigger: didLand)
    }

    private func beginGarnishFade() {
        withAnimation(.easeOut(duration: HeroFlight.garnishFadeDuration)) {
            garnishOpacity = 0
        }
        // Handles the (rare) case the hero's first layout pass -- and thus
        // its frame report -- lands before this `.task` even starts.
        if let destFrame = model.destFrame {
            beginFlight(to: destFrame)
        }
    }

    private func beginFlight(to destFrame: CGRect) {
        guard !hasStartedFlight else { return }
        hasStartedFlight = true
        // Crossfade over the final ~25% of travel as the clone converges on
        // the real hero rendering underneath (no hide/swap -- the fade
        // masks the couple of points of residual measurement error).
        withAnimation(Motion.standard.delay(HeroFlight.duration * 0.75)) {
            cloneOpacity = 0
        }
        // Clock owner: this completion is what unblocks touches and lands
        // the haptic, independent of the crossfade above.
        withAnimation(Motion.standard, completionCriteria: .logicallyComplete) {
            frame = destFrame
            cornerRadius = 0
        } completion: {
            didLand.toggle()
            model.state = .idle
            model.destFrame = nil
        }
    }

    @ViewBuilder
    private var statusPill: some View {
        switch trip.bucket() {
        case .inProgress:
            glassPill(text: "In progress", icon: nil)
        case .upcoming:
            let days = trip.daysUntilStart()
            glassPill(text: "in \(days) day\(days == 1 ? "" : "s")", icon: nil)
        case .past:
            glassPill(text: "Completed", icon: nil)
        }
    }

    private func glassPill(text: String, icon: String?) -> some View {
        HStack(spacing: Spacing.xxs) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            }
            Text(text)
        }
        .font(Typo.body(Typo.Size.caption, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(Palette.coverPillFill, in: Capsule())
    }

    private var metaRow: some View {
        HStack(spacing: Spacing.xs) {
            if let locationText {
                metaItem(icon: "mappin.circle.fill", text: locationText)
                dot
            }
            metaItem(icon: "calendar", text: startDateText)
            dot
            Text(durationText)
        }
        .font(Typo.body(Typo.Size.caption))
        .foregroundStyle(.white.opacity(0.92))
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
        }
    }

    private var dot: some View {
        Text("\u{00B7}").opacity(0.6)
    }

    /// Reuses `TripCard`'s own static formatters (kept `internal` there for
    /// exactly this kind of reuse) rather than re-deriving the same text --
    /// `TripCard.swift` itself stays untouched, per the plan.
    private var locationText: String? {
        TripCard.locationText(countryCode: trip.countryCode, destination: trip.destination)
    }

    private var startDateText: String {
        TripCard.startDateText(for: trip.startDate, asOf: .now)
    }

    private var durationText: String {
        let days = trip.durationInDays()
        return "\(days) day\(days == 1 ? "" : "s")"
    }
}
