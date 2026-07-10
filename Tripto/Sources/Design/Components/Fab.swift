import SwiftUI

/// The amber floating action button (BUILD_PLAN.md §4.2's ＋, §6.4 `Fab`) —
/// 58pt per the mockup, anchored bottom-trailing by the caller.
struct Fab: View {
    /// Visual diameter, named so call sites reasoning about clearance
    /// around the FAB (e.g. `TripView`'s toast `bottomInset`) don't repeat
    /// the `58` magic number.
    static let diameter: CGFloat = 58

    /// UX audit finding 4: the FAB's opaque band extends `diameter` (58) +
    /// its own bottom padding `Spacing.xxl` (32) = 90pt up from the
    /// container bottom, plus its ~12pt shadow radius — so scrollable
    /// content anchored bottom-trailing under it needs 102pt of bottom
    /// inset to clear the last row/card. Named here (not left as a magic
    /// number at each scroll view) so every FAB-adjacent scroll inset uses
    /// the same math `TripView`'s toast inset already did.
    static let scrollClearance: CGFloat = Spacing.xxl + diameter + Spacing.md

    let action: () -> Void
    var accessibilityLabel: String = "Add to itinerary"

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                // Deliberately fixed, not @ScaledMetric: `diameter` below is
                // a `static let` other screens key scroll-inset math off
                // (`Fab.scrollClearance` — ItineraryTabView/BookingsTabView/
                // PackingListView/TripView), so it can't become an
                // environment-dependent scaled value without breaking that
                // contract, and scaling just the glyph (up to ~3x at AX5)
                // would badly outgrow this fixed circle. The 58pt circle
                // already clears the 44pt tap-target floor at every text
                // size, and `accessibilityLabel` below carries the action
                // for VoiceOver regardless of glyph size.
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
