import SwiftUI

/// The glassy overlay circle's *visual* on its own (BUILD_PLAN.md §6.3
/// "gradient trip covers with glassy overlay pills"), with no button/action
/// wrapper — for call sites that need a different interaction wrapper than
/// a plain tap, e.g. `TripView`'s share button, which is a
/// `NavigationLink(value:)` (M3: pushes `ShareRoute` onto the shared
/// `NavigationStack`) rather than an imperative action closure.
/// `GlassCircleButton` below is just this wrapped in a `Button`.
struct GlassCircleGlyph: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 38, height: 38)
            .background(.white.opacity(0.22), in: Circle())
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}

/// The glassy overlay circle from the trip hero — back/share buttons over
/// a cover gradient. 38pt visual, ≥44pt tap target (§6.5).
struct GlassCircleButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            GlassCircleGlyph(systemImage: systemImage)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview {
    HStack(spacing: Spacing.lg) {
        GlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "Back", action: {})
        GlassCircleButton(systemImage: "square.and.arrow.up", accessibilityLabel: "Share", action: {})
    }
    .padding(Spacing.xl)
    .background(CoverGradient.dusk)
}
