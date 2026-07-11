import SwiftUI

/// Reusable decorative illustrations for the app's settled-empty "invitation"
/// states (BUILD_PLAN.md §6.6; plan D5) — layered `Palette`/`CategoryColor`
/// -filled shapes plus SF Symbol glyphs, so every fill is dark-adaptive for
/// free (no raw hex, no new assets) and each scene echoes the surface it
/// belongs to (the timeline's own rail anatomy, a suitcase, fanned boarding
/// passes) instead of being a generic glyph.
///
/// Fixed 200×130 canvas — deliberately NOT `@ScaledMetric`/Dynamic-Type
/// -reactive. Same carve-out the glyphs this replaces already used (see the
/// call sites' prior "deliberately fixed size — the headline right below
/// already carries the message" comments): there's no adjacent inline text
/// this art needs to track, and nothing here clips. `.accessibilityHidden`
/// for the same reason — the message lives in the copy beside it, never in
/// the art.
///
/// Scope: only the four settled *invitation* empty states (home, itinerary,
/// packing, bookings). Offline/pull-failed/loading placeholders keep their
/// small status glyphs untouched — status is not an invitation (D5).
struct EmptyStateArt: View {
    enum Scene: CaseIterable {
        case home, itinerary, packing, bookings
    }

    private static let canvasSize = CGSize(width: 200, height: 130)

    let scene: Scene

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One-shot intro (scale 0.97→1 + fade, `Motion.gentle`) fired once on
    /// appear; static after — no ambient/looping motion (plan D5). Routed
    /// through `Motion.m(_:reduceMotion:)` so Reduce Motion applies the end
    /// state instantly instead of animating it, same policy every other
    /// package's animations follow.
    @State private var hasAppeared = false

    var body: some View {
        ZStack {
            switch scene {
            case .home: homeArt
            case .itinerary: itineraryArt
            case .packing: packingArt
            case .bookings: bookingsArt
            }
        }
        .frame(width: Self.canvasSize.width, height: Self.canvasSize.height)
        // The home scene's horizon circle deliberately bleeds past the
        // canvas edge (D5) — clipped here so it reads as an arc instead of
        // spilling into the headline/body copy below it.
        .clipped()
        .scaleEffect(hasAppeared ? 1 : 0.97)
        .opacity(hasAppeared ? 1 : 0)
        .onAppear {
            withAnimation(Motion.m(Motion.gentle, reduceMotion: reduceMotion)) { hasAppeared = true }
        }
        .accessibilityHidden(true)
    }

    // MARK: - Home ("plan your first trip") — low horizon, climbing plane

    private var homeArt: some View {
        ZStack {
            Circle()
                .fill(Palette.mist)
                .frame(width: 260, height: 260)
                .offset(y: 145)
            Capsule()
                .fill(Palette.mist)
                .frame(width: 46, height: 16)
                .offset(x: -58, y: -18)
            Circle()
                .fill(Palette.amberSoft)
                .frame(width: 46, height: 46)
                .offset(x: 38, y: -26)
            Image(systemName: "airplane.departure")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Palette.amber)
                .rotationEffect(.degrees(-6))
                .offset(x: 54, y: -42)
        }
    }

    // MARK: - Itinerary ("nothing planned") — the timeline's own rail anatomy

    private var itineraryArt: some View {
        ZStack {
            Capsule()
                .fill(Palette.mist)
                .frame(width: 3, height: 84)
                .offset(x: -55)
            hollowNode.offset(x: -55, y: -42)
            hollowNode.offset(x: -55, y: 42)
            Image(systemName: "sparkles")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.amber)
                .offset(x: -55, y: -42)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Palette.mist, style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .frame(width: 88, height: 36)
                .offset(x: 25, y: -42)
        }
    }

    private var hollowNode: some View {
        Circle()
            .strokeBorder(Palette.mist, lineWidth: 2.5)
            .frame(width: 14, height: 14)
    }

    // MARK: - Packing ("start the family packing list") — a suitcase

    private var packingArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.mist)
                .frame(width: 108, height: 74)
                .offset(y: 18)
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Palette.amberSoft)
                .frame(width: 72, height: 26)
                .offset(y: -24)
            Image(systemName: "sunglasses")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Palette.slate)
                .offset(x: -26, y: -34)
            Image(systemName: "tshirt.fill")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(Palette.amber)
                .offset(x: 22, y: -36)
        }
    }

    // MARK: - Bookings ("bookings collect here") — two fanned passes

    private var bookingsArt: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Palette.mist)
                .frame(width: 128, height: 76)
                .rotationEffect(.degrees(-6))
                .offset(x: -14, y: 6)
            frontPass
                .rotationEffect(.degrees(6))
                .offset(x: 10, y: -6)
            Image(systemName: "ticket")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.amber)
                .offset(x: 10, y: -6)
        }
    }

    private var frontPass: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Palette.elevated)
            .frame(width: 128, height: 76)
            .overlay(alignment: .top) {
                perforation.padding(.top, 24)
            }
            // Same small-card shadow value as `TimelineRowViews`' row cards
            // — reads as "elevated" (D5) against the flatter mist pass
            // behind it.
            .shadow(color: Palette.shadow.opacity(0.08), radius: 6, y: 3)
    }

    /// A single dashed tear line — same rule+dash technique as
    /// `BookingDetailView.dashedRule`, echoing that screen's real
    /// perforated-stub physicality in miniature.
    private var perforation: some View {
        Rectangle()
            .fill(Palette.mist)
            .frame(width: 96, height: 1)
            .overlay {
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
                    .foregroundStyle(Palette.mist)
            }
    }
}

#Preview("All scenes — light") {
    ScrollView {
        VStack(spacing: Spacing.xl) {
            ForEach(EmptyStateArt.Scene.allCases, id: \.self) { EmptyStateArt(scene: $0) }
        }
        .padding(Spacing.xl)
    }
    .background(Palette.paper)
    .preferredColorScheme(.light)
}

#Preview("All scenes — dark") {
    ScrollView {
        VStack(spacing: Spacing.xl) {
            ForEach(EmptyStateArt.Scene.allCases, id: \.self) { EmptyStateArt(scene: $0) }
        }
        .padding(Spacing.xl)
    }
    .background(Palette.paper)
    .preferredColorScheme(.dark)
}
