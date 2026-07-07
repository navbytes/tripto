import SwiftUI

/// Home's trip card (BUILD_PLAN.md §4.1, §6.3 "gradient trip covers with
/// glassy overlay pills"). The whole card is the tap target — `HomeView`
/// wraps this in the `NavigationLink`/button, not this view itself, so it
/// stays a plain presentational component.
struct TripCard: View {
    let trip: Trip
    let people: [AvatarStack.Person]
    let isPending: Bool
    var today: Date = .now

    private var bucket: TripBucket { trip.bucket(asOf: today) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverGradient.from(key: trip.coverGradient)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    statusPill
                    if isPending {
                        glassPill(text: "Waiting to sync", icon: "clock")
                    }
                    Spacer(minLength: Spacing.sm)
                    AvatarStack(people: people)
                }

                Spacer(minLength: Spacing.md)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(trip.title)
                        .font(Typo.display(Typo.Size.display))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    HStack(spacing: Spacing.xs) {
                        metaItem(icon: "mappin.circle.fill", text: countryDisplayName)
                        dot
                        metaItem(icon: "calendar", text: startDateText)
                        dot
                        Text("\(trip.durationInDays()) days")
                    }
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(.white.opacity(0.92))
                }
            }
            .padding(Spacing.lg)
        }
        .frame(height: 178)
        .clipShape(RoundedRectangle(cornerRadius: Radii.cover, style: .continuous))
        .shadow(color: Palette.ink.opacity(0.22), radius: 16, y: 10)
    }

    @ViewBuilder
    private var statusPill: some View {
        switch bucket {
        case .inProgress:
            glassPill(text: "In progress", icon: nil)
        case .upcoming:
            glassPill(text: "in \(trip.daysUntilStart(asOf: today)) days", icon: nil)
        case .past:
            glassPill(text: "Completed", icon: nil)
        }
    }

    private func glassPill(text: String, icon: String?) -> some View {
        HStack(spacing: Spacing.xxs) {
            if let icon {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
            }
            Text(text)
        }
        .font(Typo.body(Typo.Size.caption, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(.white.opacity(0.22), in: Capsule())
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: icon).font(.system(size: 10))
            Text(text)
        }
    }

    private var dot: some View {
        Text("·").opacity(0.6)
    }

    /// `countryCode` is a bare ISO-3166 2-letter code (the form's field);
    /// `Locale` turns it into the display name the mockup shows ("PT" ->
    /// "Portugal") with no hand-maintained lookup table.
    private var countryDisplayName: String {
        guard trip.countryCode.count == 2 else { return trip.destination }
        return Locale.current.localizedString(forRegionCode: trip.countryCode) ?? trip.countryCode
    }

    private var startDateText: String {
        trip.startDate.formatted(.dateTime.month(.abbreviated).day())
    }
}

#Preview {
    let container = AppSchema.makeContainer(inMemory: true)
    let trip = Trip(
        id: UUID(), title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
        startDate: Calendar.current.date(byAdding: .day, value: 12, to: .now)!,
        endDate: Calendar.current.date(byAdding: .day, value: 18, to: .now)!,
        coverGradient: "dusk", tripTypeRaw: "family", createdBy: UUID(),
        createdAt: .now, updatedAt: .now, updatedBy: nil
    )
    return TripCard(
        trip: trip,
        people: [
            .init(id: UUID(), initial: "N", colorName: "amber"),
            .init(id: UUID(), initial: "P", colorName: "moss"),
        ],
        isPending: true
    )
    .padding(Spacing.xl)
    .background(Palette.paper)
    .modelContainer(container)
}
