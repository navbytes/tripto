import SwiftUI

/// The "Bookings" sub-tab (BUILD_PLAN.md §4.2 tabs) — every item that has a
/// confirmation code, flattened and grouped by category, so a traveler can
/// find "the flight confirmation" without scrolling the full day-by-day
/// timeline. Tapping a row opens the same `BookingDetailView` the timeline
/// tab's cards do, via the shared `ItemRoute` navigation destination.
struct BookingsTabView: View {
    let items: [ItineraryItem]

    private var groups: [(category: ItemCategory, items: [ItineraryItem])] {
        let withConfirmation = items.filter { !($0.confirmation ?? "").isEmpty }
        let grouped = Dictionary(grouping: withConfirmation, by: \.category)
        return ItemCategory.allCases.compactMap { category in
            guard let group = grouped[category], !group.isEmpty else { return nil }
            return (category, group.sorted { $0.startsAt < $1.startsAt })
        }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        ForEach(groups, id: \.category) { group in
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                Text(group.category.displayName.uppercased())
                                    .font(Typo.body(11, weight: .bold))
                                    .foregroundStyle(Palette.slate)
                                    .tracking(0.5)
                                    .padding(.horizontal, Spacing.lg)

                                VStack(spacing: Spacing.sm) {
                                    ForEach(group.items) { item in
                                        BookingRow(item: item)
                                    }
                                }
                                .padding(.horizontal, Spacing.lg)
                            }
                        }
                    }
                    .padding(.vertical, Spacing.lg)
                    .padding(.bottom, Spacing.xxl)
                }
            }
        }
        .background(Palette.paper)
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Image(systemName: "ticket")
                .font(.system(size: 34))
                .foregroundStyle(Palette.slate)
            Text("Confirmation codes you add will collect here.")
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)
            Spacer()
            Spacer()
        }
    }
}

private struct BookingRow: View {
    let item: ItineraryItem

    var body: some View {
        NavigationLink(value: ItemRoute(id: item.id)) {
            HStack(spacing: Spacing.md) {
                CategoryIconTile(category: item.category, side: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(Typo.body(Typo.Size.body, weight: .semibold))
                        .foregroundStyle(Palette.ink)
                        .lineLimit(1)
                    Text(TimelineBuilder.dayTitleText(item.startLocalDay))
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                }
                Spacer(minLength: Spacing.sm)
                Text(item.confirmation ?? "")
                    .font(Typo.mono(Typo.Size.caption))
                    .foregroundStyle(Palette.ink)
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Palette.slate.opacity(0.6))
            }
            .padding(Spacing.md)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}
