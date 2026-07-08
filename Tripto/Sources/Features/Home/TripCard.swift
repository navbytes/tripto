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

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var bucket: TripBucket { trip.bucket(asOf: today) }

    private var durationText: String {
        let days = trip.durationInDays()
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    /// Meta row layout (finding 5): an `HStack` truncates unreadably at
    /// accessibility sizes, so this switches to a `VStack` there — same
    /// `AnyLayout` swap pattern the mockup's `TripApp.jsx` has no equivalent
    /// for (it has no Dynamic Type concept), so this is app-original.
    private var metaLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading))
            : AnyLayout(HStackLayout(spacing: Spacing.xs))
    }

    /// Top pill row layout (finding 4): same `AnyLayout` swap as
    /// `metaLayout` — an `HStack` here has no room to wrap the status pill,
    /// the pending pill, and the avatar stack at accessibility sizes, so
    /// this stacks them leading-aligned instead. The `Spacer` is HStack-only
    /// (see below) — inside the VStack variant it would expand vertically
    /// and blow out the card's height.
    private var topLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .top, spacing: Spacing.sm))
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            CoverGradient.from(key: trip.coverGradient)
            CoverGradient.textScrim

            VStack(alignment: .leading, spacing: 0) {
                topLayout {
                    statusPill
                    if isPending {
                        glassPill(text: "Waiting to sync", icon: "clock")
                    }
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: Spacing.sm)
                    }
                    AvatarStack(people: people)
                }

                Spacer(minLength: Spacing.md)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(trip.title)
                        .font(Typo.display(Typo.Size.display))
                        .foregroundStyle(.white)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)

                    metaLayout {
                        metaItem(icon: "mappin.circle.fill", text: countryDisplayName)
                        if !dynamicTypeSize.isAccessibilitySize { dot }
                        metaItem(icon: "calendar", text: startDateText)
                        if !dynamicTypeSize.isAccessibilitySize { dot }
                        Text(durationText)
                    }
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(.white.opacity(0.92))
                }
            }
            .padding(Spacing.lg)
        }
        .frame(minHeight: 178)
        .clipShape(RoundedRectangle(cornerRadius: Radii.cover, style: .continuous))
        .shadow(color: Palette.shadow.opacity(0.22), radius: 16, y: 10)
        // One VoiceOver element: the gradient/pills/avatars are decorative
        // fragments individually, but a single spoken summary is what a
        // traveler needs. HomeView wraps this in the button (the .isButton
        // trait), so this just supplies the label. (§7.3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var accessibilityLabel: String {
        var parts = [trip.title, countryDisplayName]
        switch bucket {
        case .inProgress: parts.append("in progress")
        case .upcoming: parts.append("in \(daysUntilStartText)")
        case .past: parts.append("completed")
        }
        parts.append("starts \(startDateText)")
        parts.append(durationText)
        if !people.isEmpty {
            parts.append("\(people.count) traveler\(people.count == 1 ? "" : "s")")
        }
        if isPending { parts.append("waiting to sync") }
        return parts.joined(separator: ", ")
    }

    /// Shared with `accessibilityLabel` so the spoken and on-screen pill
    /// text pluralize identically.
    private var daysUntilStartText: String {
        let days = trip.daysUntilStart(asOf: today)
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    @ViewBuilder
    private var statusPill: some View {
        switch bucket {
        case .inProgress:
            glassPill(text: "In progress", icon: nil)
        case .upcoming:
            glassPill(text: "in \(daysUntilStartText)", icon: nil)
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
        .background(Palette.coverPillFill, in: Capsule())
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
        TripCard.startDateText(for: trip.startDate, asOf: today)
    }

    /// Split out of `startDateText` (finding 3) so it's unit-testable
    /// without standing up a whole `TripCard`. A same-year date reads as
    /// "May 14"; anything in a different year (multi-year Past-tab history,
    /// or a trip booked for next January) gets the year appended so it
    /// isn't ambiguous.
    static func startDateText(for date: Date, asOf today: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, equalTo: today, toGranularity: .year) {
            return date.formatted(.dateTime.month(.abbreviated).day())
        } else {
            return date.formatted(.dateTime.month(.abbreviated).day().year())
        }
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

/// Text-scrim contrast check (finding 2): all three cover gradients, worst
/// case (bottom-left text) is the same for each since the scrim is a fixed
/// vertical gradient independent of the cover's own diagonal — verified
/// here in both light and dark since `Palette.paper`/`Palette.ink` (used
/// only outside the card) are the only theme-adaptive pieces in frame.
#Preview("Cover gradients — light") {
    ScrollView {
        VStack(spacing: Spacing.lg) {
            ForEach(["dusk", "plum", "moss"], id: \.self) { gradient in
                TripCard.previewCard(coverGradient: gradient)
            }
        }
        .padding(Spacing.xl)
    }
    .background(Palette.paper)
    .modelContainer(AppSchema.makeContainer(inMemory: true))
}

/// Top pill row at an accessibility Dynamic Type size (finding 4) —
/// `isPending: true` so both the status pill and the "Waiting to sync"
/// pill render, exercising the wrap.
#Preview("Accessibility size") {
    ScrollView {
        TripCard.previewCard(coverGradient: "dusk")
            .padding(Spacing.xl)
    }
    .background(Palette.paper)
    .modelContainer(AppSchema.makeContainer(inMemory: true))
    .environment(\.dynamicTypeSize, .accessibility5)
}

#Preview("Cover gradients — dark") {
    ScrollView {
        VStack(spacing: Spacing.lg) {
            ForEach(["dusk", "plum", "moss"], id: \.self) { gradient in
                TripCard.previewCard(coverGradient: gradient)
            }
        }
        .padding(Spacing.xl)
    }
    .background(Palette.paper)
    .modelContainer(AppSchema.makeContainer(inMemory: true))
    .preferredColorScheme(.dark)
}

extension TripCard {
    fileprivate static func previewCard(coverGradient: String) -> some View {
        let trip = Trip(
            id: UUID(), title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: Calendar.current.date(byAdding: .day, value: 12, to: .now)!,
            endDate: Calendar.current.date(byAdding: .day, value: 18, to: .now)!,
            coverGradient: coverGradient, tripTypeRaw: "family", createdBy: UUID(),
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
    }
}
