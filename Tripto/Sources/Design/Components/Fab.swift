import SwiftUI

/// The amber floating action button (BUILD_PLAN.md §4.2's ＋, §6.4 `Fab`) —
/// 58pt per the mockup, anchored bottom-trailing by the caller.
struct Fab: View {
    /// Visual diameter, named so call sites reasoning about clearance
    /// around the FAB (e.g. `TripView`'s toast `bottomInset`) don't repeat
    /// the `58` magic number.
    static let diameter: CGFloat = 58

    let action: () -> Void
    var accessibilityLabel: String = "Add to itinerary"

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(Palette.onAmber)
                .frame(width: Self.diameter, height: Self.diameter)
                .background(Palette.amber, in: Circle())
                .shadow(color: Palette.amber.opacity(0.55), radius: 12, y: 7)
        }
        .accessibilityLabel(accessibilityLabel)
    }
}

#Preview {
    Fab(action: {})
        .padding(Spacing.xl)
        .background(Palette.paper)
}
