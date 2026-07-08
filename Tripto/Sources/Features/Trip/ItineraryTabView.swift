import SwiftUI

/// The itinerary sub-tab body (BUILD_PLAN.md §4.2 — "the core screen"): a
/// day-grouped, pinned-header timeline built from the existing
/// `ItineraryDayBucketing`/`TimelineBuilder` pure models. Purely a renderer
/// over its inputs — the FAB and its `AddItemSheet` are owned by `TripView`
/// (BUILD_PLAN.md §4.2's FAB), and a tap on any row navigates to
/// `BookingDetailView` via the shared `ItemRoute`/`NavigationStack` (see
/// `TripView.swift`'s doc comment on the one route-based nav stack rooted
/// in `HomeView`) — this view never presents a sheet itself.
struct ItineraryTabView: View {
    let trip: Trip
    let items: [ItineraryItem]
    let pendingRowIds: Set<UUID>
    let myUserId: UUID?
    let namesById: [UUID: String]
    let canEdit: Bool
    @Binding var toast: String?

    @AppStorage("importWaitlistTaps") private var importWaitlistTaps = 0

    private var dayModels: [TimelineDayModel] {
        let tripStartDay = DayDate.from(trip.startDate, calendar: .current)
        let sections = ItineraryDayBucketing.sections(items: items, tripStart: tripStartDay)
        return TimelineBuilder.build(
            sections: sections, pendingRowIds: pendingRowIds, myUserId: myUserId, namesById: namesById
        )
    }

    var body: some View {
        Group {
            if dayModels.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            ForEach(dayModels) { day in
                                Section {
                                    ForEach(day.rows) { row in
                                        rowView(for: row)
                                    }
                                } header: {
                                    dayHeader(day.title)
                                }
                            }
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Spacing.xxl * 2) // clearance for the FAB
                    }
                    .scrollDismissesKeyboard(.immediately)
                    .task {
                        #if DEBUG
                        // M2 verify-drill autopilot only (see
                        // `WelcomeView`/`HomeView`/`TripView`'s matching
                        // hooks) — scrolls to the first tz-shift chip
                        // (anchored near the top) so a screenshot can show
                        // it *and* the following day's staying strip in the
                        // same frame, with no scroll-gesture automation
                        // available in this environment.
                        if ProcessInfo.processInfo.arguments.contains("-uitestScrollTimeline") {
                            let firstChipId = dayModels
                                .flatMap(\.rows)
                                .first { if case .tzShift = $0 { true } else { false } }?
                                .id
                            let target = firstChipId ?? dayModels.dropFirst().first?.id
                            if let target {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                // `.top` lands the row exactly under the
                                // pinned section header, which can cover
                                // it; centering keeps it (and the day
                                // header, and the next day's staying
                                // strip) all clear of that overlap.
                                withAnimation { proxy.scrollTo(target, anchor: .center) }
                            }
                        }
                        #endif
                    }
                }
            }
        }
        .background(Palette.paper)
    }

    @ViewBuilder
    private func rowView(for row: TimelineRowModel) -> some View {
        switch row {
        case .card(let model): TimelineCardRow(model: model).equatable()
        case .staying(let model): StayingStripRow(model: model).equatable()
        case .checkOut(let model): CheckOutRow(model: model).equatable()
        case .tzShift(let model): TZShiftChipRow(model: model).equatable()
        }
    }

    private func dayHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(Typo.body(13, weight: .bold))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.xs)
        .background(Palette.paper)
    }

    // MARK: - Empty state (BUILD_PLAN.md §4.2, §6.6)

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                skeletonRows
                    .padding(.top, Spacing.xl)

                VStack(spacing: Spacing.xs) {
                    Text(canEdit ? "Add your first flight, stay, or plan" : "Nothing planned yet")
                        .font(Typo.display(Typo.Size.title))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                    Text(
                        canEdit
                            ? "Tap the + button to start building the itinerary."
                            : "The organizer hasn\u{2019}t added anything yet."
                    )
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Spacing.xl)

                if canEdit {
                    importTeaser
                }
            }
            .padding(.bottom, Spacing.xxl * 2)
        }
    }

    private var skeletonRows: some View {
        VStack(spacing: Spacing.md) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: Spacing.md) {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Palette.mist)
                        .frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 6) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Palette.mist).frame(width: 140, height: 12)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Palette.mist).frame(width: 90, height: 10)
                    }
                    Spacer(minLength: 0)
                }
                .padding(Spacing.md)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            }
        }
        .padding(.horizontal, Spacing.xl)
        .accessibilityHidden(true)
    }

    /// Honest import teaser (this milestone's brief: "never fake parsing").
    /// Routes to a waitlist counter, never a fabricated parse.
    private var importTeaser: some View {
        Button {
            importWaitlistTaps += 1
            toast = "We\u{2019}ll tell you when it\u{2019}s ready"
        } label: {
            HStack(spacing: Spacing.md) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "envelope.badge")
                            .foregroundStyle(Palette.amber)
                    }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Email import — v1.5")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Forward confirmations to tripto@navbytes.io once it\u{2019}s live")
                        .font(Typo.body(11))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                Text("Notify me")
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .padding(Spacing.md)
            .background(Palette.indigo, in: RoundedRectangle(cornerRadius: Radii.card + 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.xl)
        .accessibilityHint("Adds you to the email import waitlist")
    }
}
