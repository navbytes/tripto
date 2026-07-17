import SwiftUI

/// The settled-empty "invitation" scaffold shared by Home/Itinerary/Packing/
/// Bookings (BUILD_PLAN.md §6.6, plan D5): `EmptyStateArt` + a display-title/
/// body-subtitle pair, plus whatever the caller wants after it — a
/// `.primaryCapsule` CTA, a value-prop list, an import teaser, or nothing.
///
/// Renders as a flat `Group`, not a `VStack`: `Group` is transparent to its
/// enclosing container's layout (per Apple's own description of it), so
/// dropping this into a screen's existing `VStack(spacing:)` reproduces that
/// screen's own spacing/padding between art, title/subtitle, and trailing
/// content exactly — no second nested layer of spacing to reconcile against
/// each call site's own (differing) rhythm.
struct EmptyState<Content: View>: View {
    let scene: EmptyStateArt.Scene
    /// `nil` omits the title line entirely — `BookingsTabView`'s settled
    /// empty state has only a subtitle.
    var title: String?
    /// `BookingsTabView` needs a wider inset (`Spacing.xxl`); `HomeView`
    /// already gets its inset from the screen's own outer padding, so it
    /// passes `0` here to avoid double-insetting.
    var horizontalPadding: CGFloat = Spacing.xl
    /// `HomeView`'s title is the one call site that doesn't center-wrap
    /// (matches its pre-existing, un-centered layout).
    var titleAlignment: TextAlignment = .center
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        Group {
            EmptyStateArt(scene: scene)
            VStack(spacing: Spacing.xs) {
                if let title {
                    Text(title)
                        .font(Typo.display(Typo.Size.title))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(titleAlignment)
                }
                Text(subtitle)
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, horizontalPadding)
            content()
        }
    }
}

#Preview {
    ScrollView {
        VStack(spacing: Spacing.xl) {
            EmptyState(
                scene: .packing,
                title: "Start the family packing list",
                subtitle: "Passports, the car seat, chargers everyone forgets \u{2014} add what this trip needs."
            ) {
                Button("Add an item") {}
                    .buttonStyle(.primaryCapsule)
            }
            EmptyState(scene: .bookings, horizontalPadding: Spacing.xxl, subtitle: "Bookings the organizers add will collect here.") {
                EmptyView()
            }
        }
        .padding(Spacing.xl)
    }
    .background(Palette.paper)
}
