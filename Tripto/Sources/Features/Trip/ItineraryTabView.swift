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
    /// "Just mine" assignee clusters (BUILD_PLAN.md §5.4), already resolved
    /// to display-ready `AvatarStack.Person`s by `TripView` — this view
    /// stays a pure renderer and never touches `ItemAssignee`/`TripProfile`
    /// directly.
    var assigneesByItem: [UUID: [AvatarStack.Person]] = [:]
    /// First name of the person `PersonFilterBar` is currently filtering to
    /// — `nil` for "Everyone". Only changes the empty-state copy: `items`
    /// arrives already filtered (`PersonFilter.filteredItems`), so a
    /// filtered-to-zero trip that still has *other* items must not claim
    /// the trip itself has nothing planned (this milestone's brief's own
    /// context banner already states the "N of M" count above this view).
    var filteredPersonName: String? = nil
    @Binding var toast: String?

    @AppStorage("importWaitlistTaps") private var importWaitlistTaps = 0

    /// The existing tap counter already persists across launches, so it
    /// doubles as the waitlist-membership flag — no new `@AppStorage` key.
    private var isOnWaitlist: Bool { importWaitlistTaps > 0 }

    private var dayModels: [TimelineDayModel] {
        let tripStartDay = DayDate.from(trip.startDate, calendar: .current)
        let sections = ItineraryDayBucketing.sections(items: items, tripStart: tripStartDay)
        return TimelineBuilder.build(
            sections: sections, pendingRowIds: pendingRowIds, myUserId: myUserId, namesById: namesById,
            assigneesByItem: assigneesByItem
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
                        .padding(.bottom, Fab.scrollClearance)
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
                        // M4 verify drill: scrolls to the first card
                        // carrying a kid-aware tag (BUILD_PLAN.md §5.4) —
                        // same no-gesture-automation reasoning as
                        // `-uitestScrollTimeline` above.
                        if ProcessInfo.processInfo.arguments.contains("-uitestScrollToTag") {
                            let target = dayModels
                                .flatMap(\.rows)
                                .first {
                                    if case .card(let model) = $0 { !model.tags.isEmpty } else { false }
                                }?
                                .id
                            if let target {
                                try? await Task.sleep(nanoseconds: 300_000_000)
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
                if let filteredPersonName {
                    filteredEmptyState(personName: filteredPersonName)
                } else {
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
            }
            .padding(.bottom, Fab.scrollClearance)
        }
    }

    /// Shown instead of the "add your first plan" skeleton when
    /// `PersonFilterBar` has filtered the (non-empty) trip down to zero
    /// items for one person — this milestone's brief's "Just mine" filter;
    /// the trip itself isn't empty, so the day-skeleton/import-teaser below
    /// would misrepresent it as one.
    private func filteredEmptyState(personName: String) -> some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(Palette.amber)
                .padding(.bottom, Spacing.sm)
            Text("Nothing assigned to \(personName) yet")
                .font(Typo.display(Typo.Size.title))
                .foregroundStyle(Palette.ink)
                .multilineTextAlignment(.center)
            Text("Assign a plan to them from a booking\u{2019}s \u{201C}Who\u{2019}s this for?\u{201D}, or switch back to Everyone.")
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.xxl)
        .padding(.horizontal, Spacing.xl)
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
            let wasOnWaitlist = isOnWaitlist
            importWaitlistTaps += 1
            toast = wasOnWaitlist
                ? "You\u{2019}re already on the list"
                : "You\u{2019}re on the list \u{2014} we\u{2019}ll tell you when it\u{2019}s ready"
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
                    Text("Email import — coming soon")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(.white)
                    Text("Forward confirmations to tripto@navbytes.io once it\u{2019}s live")
                        .font(Typo.body(11))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                if isOnWaitlist {
                    HStack(spacing: Spacing.xxs) {
                        Image(systemName: "checkmark")
                        Text("You\u{2019}re on the list")
                    }
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(.white)
                } else {
                    Text("Notify me")
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .padding(Spacing.md)
            .background(Palette.indigo, in: RoundedRectangle(cornerRadius: Radii.card + 2, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.xl)
        .accessibilityHint(
            isOnWaitlist
                ? "You\u{2019}re on the email import waitlist"
                : "Adds you to the email import waitlist"
        )
    }
}
