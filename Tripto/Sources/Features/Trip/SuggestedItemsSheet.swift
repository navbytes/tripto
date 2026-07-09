import SwiftUI

/// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): the review inbox `ImportReviewBanner`
/// opens — every `status == 'suggested'` item on this trip, tap-through to
/// `AddItemSheet` in its confirm/dismiss mode (`isReviewingSuggestion`).
/// Presented as a `.sheet` from `TripView`, matching how `AddItemSheet`
/// itself is presented; owns its own nested `AddItemSheet` presentation the
/// same way `BookingDetailView`'s "Edit" sheet does.
///
/// `items` arrives as a plain snapshot from `TripView`'s live `@Query`, so
/// this list stays current as suggestions are confirmed/dismissed out from
/// under it (SwiftUI re-invokes this sheet's content closure whenever
/// `TripView.body` re-renders while it's presented).
struct SuggestedItemsSheet: View {
    let trip: Trip
    let items: [ItineraryItem]
    let defaultZone: TimeZone
    let onToast: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reviewingItem: ItineraryItem?

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(items) { item in
                            Button { reviewingItem = item } label: { row(item) }
                                .buttonStyle(.plain)
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .background(Palette.paper)
            .navigationTitle("Imported bookings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .sheet(item: $reviewingItem) { item in
            AddItemSheet(
                tripId: trip.id, tripTitle: trip.title, editing: item,
                defaultZone: defaultZone, tripStartDate: trip.startDate, tripCreatedBy: trip.createdBy,
                onToast: onToast
            )
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 32))
                .foregroundStyle(Palette.slate)
            Text("Nothing left to review")
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.slate)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ item: ItineraryItem) -> some View {
        HStack(spacing: Spacing.md) {
            CategoryIconTile(category: item.category, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Typo.body(Typo.Size.body, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                // The sender isn't available to the app (`email_imports` is
                // edge-function-only, deny-all RLS — CLAUDE.md's security
                // model) — the item's own date is the "reasonably available"
                // hint `docs/EMAIL_IMPORT_PLAN.md`/the brief ask for instead.
                Text("Suggested for \(TimelineBuilder.dayTitleText(item.startLocalDay))")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }
            Spacer(minLength: Spacing.sm)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.slate.opacity(0.6))
        }
        .padding(.vertical, Spacing.xxs)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(item.category.displayName), \(item.title), suggested for \(TimelineBuilder.dayTitleText(item.startLocalDay))"
        )
        .accessibilityAddTraits(.isButton)
    }
}
