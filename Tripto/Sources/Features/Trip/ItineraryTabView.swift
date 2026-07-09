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
    /// Finding 2: true while this trip's first pull this session hasn't
    /// completed yet — see `TripView.awaitingFirstTripPull`'s doc comment.
    var isAwaitingFirstSync: Bool = false
    /// Finding F7: whether the *unfiltered* trip has any items at all —
    /// `items` above arrives already filtered by `PersonFilterBar`, so this
    /// is the only way `filteredEmptyState` can tell "nothing's been added
    /// to this trip yet" apart from "everything's just hidden by the
    /// filter" and phrase its guidance accordingly.
    var hasAnyItems: Bool = true
    /// UX audit finding 1: `TimelineDayModel.id` -> how many of that day's
    /// items the current "Just mine" filter is hiding — `[:]` for
    /// "Everyone". Lets `freeDayRow` tell a genuinely free day apart from a
    /// day that's actually full for someone else (`TripView.hiddenCountByDay`
    /// via `PersonFilter.hiddenDayCounts`).
    var hiddenCountByDay: [String: Int] = [:]

    @AppStorage("importWaitlistTaps") private var importWaitlistTaps = 0
    /// Finding F1: feeds the full `DynamicTypeSize` into the row views below
    /// as `typeSize`, both so `TimelineLayout.gutterWidth` can step the
    /// gutter width with it and so their `.equatable()` short-circuit can't
    /// miss a live Dynamic Type change (see `TimelineCardRow.typeSize`'s doc
    /// comment).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// One-shot: only auto-scroll to "today" the first time this view's
    /// `.task` fires, not on every subsequent data refresh.
    @State private var hasAutoScrolledToToday = false

    /// The existing tap counter already persists across launches, so it
    /// doubles as the waitlist-membership flag — no new `@AppStorage` key.
    private var isOnWaitlist: Bool { importWaitlistTaps > 0 }

    private var tripStartDay: DayDate { DayDate.from(trip.startDate, calendar: .current) }
    private var tripEndDay: DayDate { DayDate.from(trip.endDate, calendar: .current) }

    /// Finding F8: 1-based total day count of the trip itself, used to tell
    /// "Day N" apart from "Before/After the trip" in the section titles.
    private var tripDayCount: Int {
        ItineraryDayBucketing.dayCount(from: tripStartDay, to: tripEndDay, calendar: Calendar(identifier: .gregorian)) + 1
    }

    private var dayModels: [TimelineDayModel] {
        let sections = ItineraryDayBucketing.sections(items: items, tripStart: tripStartDay, tripEnd: tripEndDay)
        return TimelineBuilder.build(
            sections: sections, pendingRowIds: pendingRowIds, myUserId: myUserId, namesById: namesById,
            assigneesByItem: assigneesByItem,
            today: DayDate.from(.now, calendar: .current),
            tripDayCount: tripDayCount
        )
    }

    /// Finding F5: `dayModels` re-runs `ItineraryDayBucketing` +
    /// `TimelineBuilder` in full every time it's read — the old `body`
    /// read it 4-5 separate times per render pass (the `isEmpty` check, the
    /// `ForEach`, both DEBUG scroll-target lookups, and `firstFreeDayId`).
    /// Evaluating it once into `models` here and threading that single
    /// snapshot through the rest of `body` (including into the `.task`
    /// closure, which captures it by value) cuts that to one run per pass.
    /// Deliberately stops there — no cross-pass cache — since there's no
    /// observed jank to justify the cache-key complexity a memoized version
    /// would need.
    var body: some View {
        let models = dayModels
        let hintDayId = firstFreeDayId(in: models)
        return Group {
            if models.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                            HeroScrollSentinel()
                            ForEach(models) { day in
                                Section {
                                    if day.isFreeDay {
                                        freeDayRow(day, showsAddHint: canEdit && day.id == hintDayId)
                                    } else {
                                        ForEach(day.rows) { row in
                                            rowView(for: row)
                                        }
                                    }
                                } header: {
                                    dayHeader(day)
                                }
                            }
                        }
                        .padding(.horizontal, Spacing.lg)
                        .padding(.bottom, Fab.scrollClearance)
                    }
                    .coordinateSpace(.named(HeroCollapse.scrollSpace))
                    .scrollDismissesKeyboard(.immediately)
                    .task {
                        // Finding F1: one-shot scroll to "today"'s section
                        // on first appearance, skipped when a DEBUG uitest
                        // drill below is about to claim the scroll position
                        // for its own screenshot target instead.
                        #if DEBUG
                        let hasUITestScrollTarget = ProcessInfo.processInfo.arguments.contains("-uitestScrollTimeline")
                            || ProcessInfo.processInfo.arguments.contains("-uitestScrollToTag")
                        #else
                        let hasUITestScrollTarget = false
                        #endif
                        if !hasUITestScrollTarget, !hasAutoScrolledToToday {
                            hasAutoScrolledToToday = true
                            let today = DayDate.from(.now, calendar: .current)
                            if today >= tripStartDay, today <= tripEndDay,
                                let target = models.first(where: { $0.id >= today.stringValue }) {
                                try? await Task.sleep(nanoseconds: 300_000_000)
                                let headerId = "day-header-\(target.id)"
                                if reduceMotion {
                                    proxy.scrollTo(headerId, anchor: .top)
                                } else {
                                    withAnimation { proxy.scrollTo(headerId, anchor: .top) }
                                }
                            }
                        }
                        #if DEBUG
                        // M2 verify-drill autopilot only (see
                        // `WelcomeView`/`HomeView`/`TripView`'s matching
                        // hooks) — scrolls to the first tz-shift chip
                        // (anchored near the top) so a screenshot can show
                        // it *and* the following day's staying strip in the
                        // same frame, with no scroll-gesture automation
                        // available in this environment.
                        if ProcessInfo.processInfo.arguments.contains("-uitestScrollTimeline") {
                            let firstChipId = models
                                .flatMap(\.rows)
                                .first { if case .tzShift = $0 { true } else { false } }?
                                .id
                            let target = firstChipId ?? models.dropFirst().first?.id
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
                            let target = models
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
        case .card(let model): TimelineCardRow(model: model, typeSize: dynamicTypeSize).equatable()
        case .staying(let model): StayingStripRow(model: model, typeSize: dynamicTypeSize).equatable()
        case .checkOut(let model): CheckOutRow(model: model, typeSize: dynamicTypeSize).equatable()
        case .tzShift(let model): TZShiftChipRow(model: model, typeSize: dynamicTypeSize).equatable()
        }
    }

    /// Finding F6: cards scrolling under the pinned header used to hard-clip
    /// against its flat `Palette.paper` fill — this replaces that fill with
    /// a paper-to-clear scrim over the header's bottom ~8pt, so a card
    /// scrolling underneath fades out instead of vanishing at a hard edge.
    /// When the header isn't pinned (its own section is in normal scroll
    /// flow, nothing behind it) the scrim renders paper-on-paper and is
    /// invisible, so the settled, non-overlapping case is unchanged.
    /// Rejected: a permanent 1pt mist hairline under every header
    /// (`PersonFilterBar`'s treatment) — that changes the timeline's visual
    /// rhythm every day for what's only a mid-scroll overlap, not a
    /// standing boundary.
    private var dayHeaderBackground: some View {
        VStack(spacing: 0) {
            Palette.paper
            LinearGradient(colors: [Palette.paper, Palette.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 8)
        }
    }

    private func dayHeader(_ day: TimelineDayModel) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(day.title)
                .font(Typo.body(13, weight: .bold))
                .foregroundStyle(Palette.ink)
            // Finding F1: a quiet "today" marker so the current day doesn't
            // require scanning dates to find — paired with the one-shot
            // auto-scroll in `.task` above. Finding 1: `.ink` (not `.amber`,
            // which was under AA contrast on `amberSoft`) — the same
            // ink-on-amberSoft pairing `TZShiftChipRow`/`PersonFilterBanner`
            // already use; keep it that way if this chip is touched again.
            if day.isToday {
                Text("Today")
                    .font(Typo.body(10, weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, Spacing.sm)
                    .padding(.vertical, 2)
                    .background(Palette.amberSoft, in: Capsule())
            }
            Spacer(minLength: 0)
        }
        .padding(.top, Spacing.lg)
        .padding(.bottom, Spacing.xs)
        .background(dayHeaderBackground)
        // Finding 4: one VoiceOver heading per day — merges the "Today"
        // chip into the date it modifies (instead of a disconnected second
        // stop) and enables the headings rotor to jump between days on long
        // trips (§4.2/§7.3).
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.isToday ? "\(day.title), Today" : day.title)
        .accessibilityAddTraits(.isHeader)
        .id("day-header-\(day.id)")
    }

    /// Finding F2: a gap day the bucketing layer filled in (no rows at
    /// all) — a quiet, non-interactive row rather than letting the day
    /// vanish from the list; the FAB already floats over this tab, so this
    /// doesn't need to be its own add affordance.
    ///
    /// Finding 8: the "tap + to add a plan" hint used to repeat on every
    /// free day, which reads as nagging on a trip with several gap days.
    /// `showsAddHint` is `true` only for the first free day an editor sees
    /// (computed once via `firstFreeDayId` below); every other gap day —
    /// and every free day for a viewer, who has no + to tap — gets the
    /// quiet "Free day" label instead.
    ///
    /// UX audit finding 1: "Free day" is a lie when it's actually full for
    /// someone the filter is hiding — `hiddenCountByDay` tells the two
    /// apart. A single `Text` either way, so VoiceOver still reads it as
    /// one stop.
    private func freeDayRow(_ day: TimelineDayModel, showsAddHint: Bool) -> some View {
        let hiddenCount = hiddenCountByDay[day.id, default: 0]
        let text: String
        if let filteredPersonName, hiddenCount > 0 {
            text = "Nothing for \(filteredPersonName) this day \u{2014} \(hiddenCount) plan\(hiddenCount == 1 ? "" : "s") hidden"
        } else {
            text = showsAddHint ? "Free day \u{2014} tap + to add a plan" : "Free day"
        }
        return HStack {
            Text(text)
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
            Spacer(minLength: 0)
        }
        .padding(.leading, TimelineLayout.indentedLeading(for: dynamicTypeSize))
        .padding(.vertical, Spacing.sm)
    }

    /// Finding 8: the id of the first free day in `models`, so the "tap +
    /// to add a plan" hint appears exactly once instead of on every gap day.
    ///
    /// UX audit finding 1 + 6: only a *genuinely* free day (nothing hidden
    /// by the filter either) is eligible — hinting "tap + to add a plan" on
    /// a day that's actually full for someone else would invite a double
    /// booking. Among genuinely free days, prefers the first on or after
    /// today (the same sortable `DayDate.stringValue` comparison the
    /// auto-scroll in `.task` above already relies on) so the hint
    /// re-anchors to the first actionable day on an in-progress trip,
    /// falling back to the first overall for trips wholly in the future or
    /// past.
    ///
    /// Finding F5: takes the already-computed `models` snapshot (rather than
    /// re-reading `dayModels` itself) so `body`'s single evaluation per
    /// render pass covers this too.
    private func firstFreeDayId(in models: [TimelineDayModel]) -> String? {
        let genuinelyFree = models.filter { $0.isFreeDay && hiddenCountByDay[$0.id, default: 0] == 0 }
        let todayId = DayDate.from(.now, calendar: .current).stringValue
        return genuinelyFree.first(where: { $0.id >= todayId })?.id ?? genuinelyFree.first?.id
    }

    // MARK: - Empty state (BUILD_PLAN.md §4.2, §6.6)

    /// Finding F2: ordering contract, don't regress it. The loading branch
    /// must come *before* the filter branch, not after — both use
    /// `hasAnyItems`/`isAwaitingFirstSync` to decide what's actually known,
    /// so they need to agree on which fact wins when both could apply.
    /// `isAwaitingFirstSync && !hasAnyItems` means the trip's first pull
    /// this session hasn't finished *and* nothing's loaded yet, so whether
    /// a person filter is hiding items or the trip is just genuinely empty
    /// is unknowable — that ambiguity, not the filter selection, is what
    /// should drive the copy. Once `hasAnyItems` is true (or the pull has
    /// settled), the filter branch is safe to answer honestly again, and
    /// `filteredEmptyGuidance`'s own `hasAnyItems` guard (below) is only
    /// ever reached post-settle, where "Add a plan with the + button first"
    /// is a fact rather than a guess.
    private var emptyState: some View {
        ScrollView {
            VStack(spacing: Spacing.xl) {
                if isAwaitingFirstSync && !hasAnyItems {
                    // Finding 2: a freshly-claimed (or just-opened) trip's
                    // itinerary can't yet be told apart from a genuinely
                    // empty one while its first pull is still in flight —
                    // `skeletonRows` reads as "loading" either way, but the
                    // headline/body below asserted facts ("nothing planned")
                    // not yet known, and the import teaser is suppressed
                    // since it's not the moment to pitch a waitlist.
                    skeletonRows
                        .padding(.top, Spacing.xl)

                    VStack(spacing: Spacing.xs) {
                        ProgressView()
                        Text("Checking this trip\u{2019}s plans\u{2026}")
                            .font(Typo.body())
                            .foregroundStyle(Palette.slate)
                    }
                } else if let filteredPersonName {
                    filteredEmptyState(personName: filteredPersonName)
                } else {
                    // Finding F11: this branch is the *settled* empty
                    // state (sync finished, trip really has nothing) — a
                    // real day skeleton reads as "start planning" rather
                    // than the grey placeholder rows above, which look
                    // identical to "still loading."
                    daySkeleton
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
    ///
    /// Finding F6: `PersonFilterBanner` (shown just above this view) already
    /// states the factual "Nothing is assigned to \(name) yet" sentence, so
    /// this drops the duplicate headline and keeps only the icon plus one
    /// guidance sentence.
    private func filteredEmptyState(personName: String) -> some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(Palette.amber)
                .padding(.bottom, Spacing.sm)
                .accessibilityHidden(true)
            Text(filteredEmptyGuidance(personName: personName))
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Spacing.xxl)
        .padding(.horizontal, Spacing.xl)
    }

    /// Finding F7: the old copy always assumed there was *something* on the
    /// unfiltered trip to assign — for an organizer looking at a genuinely
    /// empty trip, or a viewer who can't assign anything at all, that's
    /// misleading. Branches on `canEdit`/`hasAnyItems` instead.
    ///
    /// Finding F2: this function is only ever reached from `emptyState`'s
    /// filter branch, which now runs *after* the loading branch — so by the
    /// time `hasAnyItems` is read here, either the first pull has settled
    /// or something was already loaded before it started. The
    /// `!hasAnyItems` case below is a real, known fact at this point, not a
    /// guess made mid-load.
    private func filteredEmptyGuidance(personName: String) -> String {
        guard canEdit else {
            return "Switch back to Everyone to see the whole trip."
        }
        guard hasAnyItems else {
            return "Add a plan with the + button first, then assign it to \(personName)."
        }
        return "Assign a plan to them from a booking\u{2019}s \u{201C}Who\u{2019}s this for?\u{201D}, or switch back to Everyone."
    }

    /// Finding F11: loading-only now — the settled "genuinely empty" case
    /// below renders `daySkeleton` instead, so these grey placeholders only
    /// ever appear while `isAwaitingFirstSync` is actually true.
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

    /// Finding F11: the settled empty state's skeleton — up to the first 3
    /// of the trip's own real day headers (actual dates, via
    /// `TimelineBuilder.dayTitleText`) with a dashed add-slot under Day 1,
    /// so it reads as "here's your itinerary, start filling it in" rather
    /// than a generic loading placeholder.
    ///
    /// Finding 3: the dashed Day-1 slot is an add-affordance, so it's
    /// `canEdit`-gated — a viewer sees only the three real day headers, no
    /// add-slot, consistent with them having no + FAB. Finding 7: its
    /// placeholder text no longer repeats the "add your first flight, stay,
    /// or plan" invitation already said once in the display-serif headline
    /// below — a quieter, non-duplicating "Your first plan goes here"
    /// instead.
    private var daySkeleton: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            ForEach(0..<max(min(3, tripDayCount), 0), id: \.self) { offset in
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Day \(offset + 1) \u{00B7} \(skeletonDayTitleText(forDayOffset: offset))")
                        .font(Typo.body(13, weight: .bold))
                        .foregroundStyle(Palette.ink)
                    if offset == 0, canEdit {
                        RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                            .strokeBorder(Palette.mist, style: StrokeStyle(lineWidth: 1.25, dash: [5, 4]))
                            .frame(height: 54)
                            .overlay {
                                Text("Your first plan goes here")
                                    .font(Typo.body(Typo.Size.caption))
                                    .foregroundStyle(Palette.slate)
                            }
                    }
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        .accessibilityHidden(true)
    }

    private func skeletonDayTitleText(forDayOffset offset: Int) -> String {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        let date = utcCalendar.date(byAdding: .day, value: offset, to: tripStartDay.asDate(calendar: utcCalendar))
        let day = date.map { DayDate.from($0, calendar: utcCalendar) } ?? tripStartDay
        return TimelineBuilder.dayTitleText(day)
    }

    /// Honest import teaser (this milestone's brief: "never fake parsing").
    /// Routes to a waitlist counter, never a fabricated parse.
    ///
    /// Finding 9: this used to be one giant `Button` — the icon, the
    /// "coming soon" copy, and the forward-address hint all enrolled in the
    /// waitlist on tap, which reads as an accidental sign-up trap. Now only
    /// the explicit CTA is a button; the rest of the card is static
    /// informational content (`.accessibilityElement(children: .combine)`
    /// so VoiceOver still reads it as one stop). The old "already on the
    /// list" re-tap toast goes away with the tap surface — there's nothing
    /// left to accidentally re-tap.
    ///
    /// UX audit finding 3: the copy previously promised a real waitlist
    /// ("You're on the list — we'll tell you when it's ready"), but the
    /// mechanism behind it is only a device-local `@AppStorage` tap
    /// counter — nothing is actually sent anywhere, and no one gets
    /// notified. The wording below claims only what that counter can
    /// honestly deliver ("noted interest," not "you'll be notified"); a
    /// real server-side waitlist capture is deferred to the backend repo.
    /// The counter, `isOnWaitlist` gate, and persistence semantics are all
    /// unchanged.
    private var importTeaser: some View {
        HStack(spacing: Spacing.md) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.18))
                .frame(width: 40, height: 40)
                .overlay {
                    Image(systemName: "envelope.badge")
                        .foregroundStyle(Palette.amber)
                }
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Email import — coming soon")
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(.white)
                Text("Forward confirmations to tripto@navbytes.io once it\u{2019}s live")
                    .font(Typo.body(11))
                    .foregroundStyle(.white.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: Spacing.sm)
            if isOnWaitlist {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "checkmark")
                    Text("Interest noted \u{2014} thanks!")
                }
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(.white)
                .accessibilityElement(children: .combine)
            } else {
                Button {
                    importWaitlistTaps += 1
                    toast = "Thanks \u{2014} we\u{2019}re building email import."
                } label: {
                    Text("I want this")
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, Spacing.md)
                        .padding(.vertical, Spacing.xs)
                        .background(Color.white.opacity(0.18), in: Capsule())
                        // Same 44pt hit-band pattern as `PersonFilterBar`'s
                        // chips — a smaller visual capsule centered in a
                        // 44pt hit area.
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Registers your interest in email import")
            }
        }
        .padding(Spacing.md)
        .background(Palette.indigo, in: RoundedRectangle(cornerRadius: Radii.card + 2, style: .continuous))
        .padding(.horizontal, Spacing.xl)
    }
}
