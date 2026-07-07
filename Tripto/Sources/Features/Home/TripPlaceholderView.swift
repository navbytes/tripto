import SwiftUI

/// Where a tapped trip card goes until M2 builds the real itinerary
/// timeline (BUILD_PLAN.md §4.2). Deliberately minimal — just enough to
/// prove navigation and show which trip was opened.
struct TripPlaceholderView: View {
    let trip: Trip

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            VStack(spacing: Spacing.md) {
                Text(trip.title)
                    .font(Typo.display())
                    .foregroundStyle(Palette.ink)
                Text("Itinerary lands in M2")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
            }
            .padding(Spacing.xl)
        }
        .navigationTitle(trip.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
