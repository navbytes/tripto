import SwiftUI

/// The "Bookings" sub-tab (BUILD_PLAN.md §4.2 tabs) — every item that has a
/// confirmation code, flattened and grouped by category, so a traveler can
/// find "the flight confirmation" without scrolling the full day-by-day
/// timeline. Tapping a row opens the same `BookingDetailView` the timeline
/// tab's cards do, via the shared `ItemRoute` navigation destination.
struct BookingsTabView: View {
    let items: [ItineraryItem]
    /// Invokes `TripView`'s `AddItemSheet` presentation (finding 6) — `nil`
    /// for viewers, who get read-only copy instead of a routing affordance.
    /// Backs the empty state's CTA; `TripView` also shows the shared FAB on
    /// this tab for editors (UX audit finding 5), so this isn't the only
    /// entry point once there's at least one booking on screen.
    var onAdd: (() -> Void)? = nil

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
                    .padding(.bottom, Spacing.xxl * 2) // clearance for the FAB
                }
            }
        }
        .background(Palette.paper)
    }

    // Finding 6 (§6.6 invitation copy): the old state just described what
    // would happen ("confirmation codes you add will collect here") without
    // giving the organizer a way to make it happen — a dead end on the one
    // tab whose entire purpose is "find the confirmation code." An editor
    // gets an invitation with a route; a viewer gets the honest read-only
    // version of the same sentence.
    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            Image(systemName: "ticket")
                .font(.system(size: 34))
                .foregroundStyle(Palette.slate)
            Text(
                onAdd != nil
                    ? "Add a flight or stay with its confirmation code \u{2014} bookings collect here automatically."
                    : "Bookings the organizers add will collect here."
            )
            .font(Typo.body())
            .foregroundStyle(Palette.slate)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xxl)
            if let onAdd {
                Button(action: onAdd) {
                    Text("Add your first booking")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(Palette.onAmber)
                        .padding(.horizontal, Spacing.xl)
                        .padding(.vertical, Spacing.md)
                        .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor
                        .contentShape(Capsule())
                        .background(Palette.amber, in: Capsule())
                }
                .padding(.top, Spacing.xs)
            }
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
