import SwiftUI

/// The glassy overlay circle from the trip hero (BUILD_PLAN.md §6.3
/// "gradient trip covers with glassy overlay pills") — back/share buttons
/// over a cover gradient. 38pt visual, ≥44pt tap target (§6.5).
struct GlassCircleButton: View {
    let systemImage: String
    let accessibilityLabel: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(.white.opacity(0.22), in: Circle())
                .frame(width: 44, height: 44)
                .contentShape(Circle())
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
