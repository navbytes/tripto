import SwiftUI

/// The filled amber-capsule primary CTA (BUILD_PLAN.md §6.4) — semibold body
/// text on `Palette.onAmber`, `Spacing.xl`/`Spacing.md` padding, the
/// `TapTarget.minHeight` 44pt floor, and `.contentShape` sized before the
/// capsule fill paints on top of it (fill last is what makes the *visible*
/// capsule actually grow to the 44pt floor, not just its invisible tap
/// band — a fix-round bug elsewhere in this codebase when the order was
/// reversed).
///
/// Was hand-copied at 9 call sites (`HomeView`, `TripView`,
/// `BookingDetailView`, `BookingsTabView`, `PackingListView`,
/// `ItineraryTabView`). Apply as `.buttonStyle(.primaryCapsule)` to any
/// `Button` — the label can be a plain `Text` or compound content (e.g. an
/// `HStack` with a conditional `ProgressView`), same as every site above
/// already varied it.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Typo.body(weight: .semibold))
            .foregroundStyle(Palette.onAmber)
            .padding(.horizontal, Spacing.xl)
            .padding(.vertical, Spacing.md)
            .frame(minHeight: TapTarget.minHeight)
            .contentShape(Capsule())
            .background(Palette.amber, in: Capsule())
    }
}

extension ButtonStyle where Self == PrimaryCapsuleButtonStyle {
    static var primaryCapsule: PrimaryCapsuleButtonStyle { PrimaryCapsuleButtonStyle() }
}

#Preview {
    VStack(spacing: Spacing.lg) {
        Button("Plan a new trip") {}
            .buttonStyle(.primaryCapsule)
        Button {
        } label: {
            HStack(spacing: Spacing.xs) {
                ProgressView().tint(Palette.onAmber)
                Text("Trying again\u{2026}")
            }
        }
        .buttonStyle(.primaryCapsule)
    }
    .padding(Spacing.xl)
    .background(Palette.paper)
}
