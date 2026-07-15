import SwiftUI

/// docs/UX_REDESIGN_ROADMAP.md Phase 5: register-specific augmentation for
/// the nearest-upcoming ("next") or live ("now") trip — `HomeView` resolves
/// which one applies (`HomeRegister.kind`, `HomeRegisters.swift`) and hands
/// the already-built content down; `.plain` (every other card, the default)
/// renders exactly as `TripCard` did before this phase.
enum HomeCardRegister: Equatable {
    case plain
    case next(firstUp: HomeFirstUp?)
    case now(panel: HomeTodayPanel)
}

/// Home's trip card (BUILD_PLAN.md §4.1, §6.3 "gradient trip covers with
/// glassy overlay pills"). The whole card is the tap target — `HomeView`
/// wraps this in the `NavigationLink`/button, not this view itself, so it
/// stays a plain presentational component.
struct TripCard: View {
    let trip: Trip
    let people: [AvatarStack.Person]
    let isPending: Bool
    var today: Date = .now
    var register: HomeCardRegister = .plain

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var smallGlyphSize: CGFloat = 10

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
                        glassPill(text: "Waiting to sync", leading: .icon("clock"))
                    }
                    if !dynamicTypeSize.isAccessibilitySize {
                        Spacer(minLength: Spacing.sm)
                    }
                    AvatarStack(people: people)
                }

                Spacer(minLength: Spacing.md)

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    // P7b craft-audit fix: hard-truncated at 1 line even at
                    // default Dynamic Type size ("Marrakech Long We…") — a
                    // register card has no fixed/max height (`.frame(
                    // minHeight:)` below is a floor only), so a second line
                    // just grows the card, same as any other longer content
                    // already does; the trip-DETAIL hero (`TripHeroView`,
                    // Features/Trip/HeroCollapse.swift) stays 1-line by its
                    // own deliberate "no two-line wrap" rule and is
                    // unaffected by this.
                    Text(trip.title)
                        .font(Typo.display(Typo.Size.display))
                        .foregroundStyle(.white)
                        .lineLimit(2)

                    metaLayout {
                        if let locationText {
                            metaItem(icon: "mappin.circle.fill", text: locationText)
                            if !dynamicTypeSize.isAccessibilitySize { dot }
                        }
                        metaItem(icon: "calendar", text: startDateText)
                        if !dynamicTypeSize.isAccessibilitySize { dot }
                        Text(durationText)
                    }
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(.white.opacity(0.92))
                }

                registerContent
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
        var parts = [trip.title]
        if let locationText { parts.append(locationText) }
        parts.append(statusAccessibilityPhrase)
        parts.append("starts \(startDateText)")
        parts.append(durationText)
        if !people.isEmpty {
            parts.append("\(people.count) traveler\(people.count == 1 ? "" : "s")")
        }
        if isPending { parts.append("waiting to sync") }
        // P5.2/P5.3: "sensible per-card sentences" for the registers'
        // on-card extras (§ contract) — the ring/day-progress-bar/mini-list
        // views themselves stay out of the accessibility tree (see
        // `HomeRegisterViews.swift`), so this is the one place their
        // content actually reaches VoiceOver.
        if let registerAccessibilityPhrase { parts.append(registerAccessibilityPhrase) }
        return parts.joined(separator: ", ")
    }

    /// The bucket-status phrase — "Day N of M" for the live "now" register
    /// (richer than the plain "in progress" every other in-progress card
    /// still says), the existing phrasing otherwise.
    private var statusAccessibilityPhrase: String {
        if case .now(let panel) = register {
            return "day \(panel.dayNumber) of \(panel.totalDays)"
        }
        switch bucket {
        case .inProgress: return "in progress"
        case .upcoming: return "in \(daysUntilStartText)"
        case .past: return "completed"
        }
    }

    private var registerAccessibilityPhrase: String? {
        switch register {
        case .plain:
            return nil
        case .next(let firstUp):
            guard let firstUp else { return nil }
            return "first up: \(firstUp.text), \(firstUp.weekday) \(firstUp.time)"
        case .now(let panel):
            guard !panel.rows.isEmpty else { return nil }
            var todayParts = panel.rows.map { "\($0.time) \($0.title)" }
            if panel.moreCount > 0 {
                todayParts.append("\(panel.moreCount) more today")
            }
            return "today: " + todayParts.joined(separator: ", ")
        }
    }

    /// Shared with `accessibilityLabel` so the spoken and on-screen pill
    /// text pluralize identically.
    private var daysUntilStartText: String {
        let days = trip.daysUntilStart(asOf: today)
        return "\(days) day\(days == 1 ? "" : "s")"
    }

    /// P5.2/P5.3: the "next"/"now" registers override the plain bucket pill
    /// — "next" keeps the existing "in N days" text but adds the countdown
    /// ring bullet, "now" swaps in "Day N of M" with the live dot. Every
    /// other card (`.plain`, incl. every non-first "ahead" trip) is
    /// unchanged from before this phase.
    @ViewBuilder
    private var statusPill: some View {
        switch register {
        case .now(let panel):
            glassPill(text: "Day \(panel.dayNumber) of \(panel.totalDays)", leading: .liveDot)
        case .next:
            glassPill(text: "in \(daysUntilStartText)", leading: .ring(fraction: countdownRingFraction))
        case .plain:
            switch bucket {
            case .inProgress:
                glassPill(text: "In progress")
            case .upcoming:
                glassPill(text: "in \(daysUntilStartText)")
            case .past:
                glassPill(text: "Completed")
            }
        }
    }

    /// P5.2: docs/UX_REDESIGN_ROADMAP.md's own review call — true
    /// elapsed-since-creation progress read as over-engineered for a
    /// glance-only decoration the mockup only ever shows as a simple partial
    /// arc. ponytail: linear against a 60-day ceiling, clamped — a trip
    /// further out than that just shows a full ring; there's no ambition
    /// here beyond "closer trips read differently from farther ones."
    private var countdownRingFraction: Double {
        min(max(Double(trip.daysUntilStart(asOf: today)), 0), 60) / 60
    }

    private enum PillLeading {
        case none
        case icon(String)
        case ring(fraction: Double)
        case liveDot
    }

    private func glassPill(text: String, leading: PillLeading = .none) -> some View {
        HStack(spacing: Spacing.xxs) {
            switch leading {
            case .none:
                EmptyView()
            case .icon(let name):
                Image(systemName: name).font(.system(size: smallGlyphSize, weight: .semibold))
            case .ring(let fraction):
                CountdownRing(fraction: fraction)
            case .liveDot:
                LiveDot()
            }
            Text(text)
        }
        .font(Typo.body(Typo.Size.caption, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(Palette.coverPillFill, in: Capsule())
    }

    /// The register's own extra content, appended below the title/meta
    /// block — `EmptyView` for `.plain`, matching every card before this
    /// phase exactly.
    @ViewBuilder
    private var registerContent: some View {
        switch register {
        case .plain:
            EmptyView()
        case .next(let firstUp):
            if let firstUp {
                FirstUpStrip(model: firstUp)
                    .padding(.top, Spacing.md)
            }
        case .now(let panel):
            VStack(alignment: .leading, spacing: Spacing.sm + 4) {
                DayProgressBar(dayNumber: panel.dayNumber, totalDays: panel.totalDays)
                if !panel.rows.isEmpty {
                    TodayPanelView(panel: panel)
                }
            }
            .padding(.top, Spacing.md)
        }
    }

    private func metaItem(icon: String, text: String) -> some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: icon).font(.system(size: smallGlyphSize))
            Text(text)
        }
    }

    private var dot: some View {
        Text("·").opacity(0.6)
    }

    /// `nil` when there's nothing to show for location (finding 6) — a
    /// title-only trip shouldn't render a dangling map-pin + separator with
    /// no text after it.
    private var locationText: String? {
        TripCard.locationText(countryCode: trip.countryCode, destination: trip.destination)
    }

    /// Split out of `locationText` (finding 6) so it's unit-testable without
    /// standing up a whole `TripCard`, mirroring `startDateText` below.
    /// `countryCode` is a bare ISO-3166 2-letter code (the form's field);
    /// `Locale` turns it into the display name the mockup shows ("PT" ->
    /// "Portugal") with no hand-maintained lookup table. Falls back to the
    /// free-text `destination`, and to `nil` (nothing to show) only when
    /// both are blank.
    static func locationText(countryCode: String, destination: String) -> String? {
        if countryCode.count == 2 {
            return Locale.current.localizedString(forRegionCode: countryCode) ?? countryCode
        }
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDestination.isEmpty ? nil : destination
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
            .init(id: UUID(), initial: "P", colorName: "moss")
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
                .init(id: UUID(), initial: "P", colorName: "moss")
            ],
            isPending: true
        )
    }
}
