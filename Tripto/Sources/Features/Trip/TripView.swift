import SwiftData
import SwiftUI

/// Value routes for the one `NavigationStack` (rooted in `HomeView`).
/// Distinct wrapper types — not bare `UUID`s — so trip/item/share/settings
/// destinations can't collide in the same path.
struct TripRoute: Hashable {
    let id: UUID
    /// Set only when this push follows a successful invite claim (M3
    /// `AppRouter`) — shown once as a "You're in" toast when `TripView`
    /// appears (see `initialToast`), then discarded; not otherwise part of
    /// a trip route's identity in any meaningful sense.
    var welcomeToast: String?
}

struct ItemRoute: Hashable {
    let id: UUID
}

/// M3: `ShareTripView` (Features/Share/ShareTripView.swift), pushed from
/// this trip's hero share button.
struct ShareRoute: Hashable {
    let tripId: UUID
}

/// M3: `SettingsView` (Features/Settings/SettingsView.swift), pushed from
/// `HomeView`'s avatar tap. No associated data — one settings screen, not
/// per-trip.
struct SettingsRoute: Hashable {}


/// The trip screen (BUILD_PLAN.md §4.2 — THE core screen): cover-gradient
/// hero, Itinerary · Bookings sub-tabs (Map/$ Split hidden per §9.4), and
/// the day-grouped timeline. Renders entirely from the local SwiftData
/// mirror; `onAppear`/`onDisappear` drive the per-trip realtime channel and
/// debounced pull (SYNC_DESIGN.md "Realtime").
struct TripView: View {
    let tripId: UUID
    /// Shown once as a toast on appear (M3: set by `HomeView` after a
    /// successful invite claim — "You're in — welcome to {trip}"). `nil`
    /// for every normal navigation into a trip.
    var initialToast: String?

    @Query private var trips: [Trip]
    @Query private var items: [ItineraryItem]
    @Query private var members: [TripMember]
    @Query private var tripProfiles: [TripProfile]
    @Query private var profiles: [Profile]
    /// Unfiltered, like `tripProfiles`' siblings on other screens —
    /// `ItemAssignee` has no `tripId` of its own (composite PK item_id+
    /// profile_id; see its doc comment), so this scopes to the current trip
    /// by cross-referencing `items`' ids instead of a predicate here.
    @Query private var itemAssignees: [ItemAssignee]

    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(SyncStatus.self) private var syncStatus
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Finding 4: `tabBar()`'s AX-size horizontal-scroll branch, same
    /// `isAccessibilitySize` convention as `TripCard.swift`.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var selectedTab: Tab = .itinerary
    @State private var isPresentingAdd = false
    @State private var isEditingTrip = false
    @State private var toast: String?
    /// "Just mine" selection (BUILD_PLAN.md §5.4) — `nil` is "Everyone."
    @State private var selectedProfileFilter: UUID?
    @Namespace private var tabUnderline

    // M2 verify-drill autopilot only (see `WelcomeView`/`HomeView`'s
    // matching hooks) — a DEBUG-only alternate presentation path for
    // `BookingDetailView` so the screenshot pass can reach it with no GUI
    // tap automation available in this environment; real navigation still
    // goes through `ItemRoute`/`NavigationLink` as normal.
    @State private var showUITestBookingDetail = false
    @State private var uitestBookingDetailItemId: UUID?

    enum Tab: String, CaseIterable {
        case itinerary = "Itinerary"
        case bookings = "Bookings"
        case packing = "Packing"
    }

    init(tripId: UUID, initialToast: String? = nil) {
        self.tripId = tripId
        self.initialToast = initialToast
        _trips = Query(filter: #Predicate<Trip> { $0.id == tripId })
        _items = Query(
            filter: #Predicate<ItineraryItem> { $0.tripId == tripId },
            sort: \ItineraryItem.startsAt
        )
        _members = Query(filter: #Predicate<TripMember> { $0.tripId == tripId })
        _tripProfiles = Query(filter: #Predicate<TripProfile> { $0.tripId == tripId })
    }

    private var trip: Trip? { trips.first }

    private var myRole: TripRole? {
        guard let userId = authManager.userId else { return nil }
        return members.first { $0.userId == userId }?.role
    }

    /// Role gate for the FAB and all edit affordances — mirrors RLS
    /// convenience-only (CLAUDE.md): viewers see a read-only trip.
    ///
    /// Finding 7: `myRole != .viewer` alone can't tell a signed-out local
    /// creator (whose `TripMember` row only ever exists locally, and is
    /// therefore always "resolved") apart from a signed-in joiner whose
    /// membership row simply hasn't arrived from the first pull yet — both
    /// read as `nil`. Distinguishing the two nil cases: a signed-out user is
    /// always the legitimately-permitted local creator; a signed-in user
    /// with no resolved role yet is mid-first-pull and should see a
    /// read-only trip until RLS would actually let them write.
    /// `TripFormView.swift`'s trip-creation path inserts a local organizer
    /// `TripMember` synchronously, so a signed-in creator always has a
    /// resolved role by the time this is read — only joiners are affected.
    private var canAddItems: Bool {
        guard authManager.userId != nil else { return true }
        guard let myRole else { return false }
        return myRole != .viewer
    }

    /// Finding 2: the hero pencil's own gate was `myRole == .organizer`
    /// only — that reads `nil` for a signed-out local creator (whose
    /// `TripMember` row is always locally resolved, never fetched), so it
    /// was hiding the edit affordance for the one person who legitimately
    /// owns the trip. Same "signed-out = local creator" rule `canAddItems`
    /// already codifies (see its doc comment above), applied to the
    /// organizer-only edit surface instead of the broader add/edit-item one.
    private var canEditTrip: Bool {
        guard authManager.userId != nil else { return true }
        return myRole == .organizer
    }

    /// Finding 2: mirrors `SyncStatus.hasCompletedInitialHomePull`'s
    /// loading-vs-empty distinction, scoped to this one trip
    /// (`completedInitialTripPulls`) — a freshly-claimed or just-opened
    /// trip's genuinely-empty tabs can't yet be told apart from "haven't
    /// heard from the server yet." Signed-out is excluded: no pull ever
    /// runs for a signed-out session (their data is local-only), so there's
    /// nothing to "await." Offline is excluded too: `SyncBanner` already
    /// explains the state, and the underlying flag can never be set while
    /// offline (`pullTrip`'s own early-return guard).
    private var awaitingFirstTripPull: Bool {
        authManager.userId != nil && !syncStatus.isOffline && !syncStatus.completedInitialTripPulls.contains(tripId)
    }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            if let trip {
                content(for: trip)
            } else {
                missingTripState
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Finding 1: `.toolbar(.hidden, for: .navigationBar)` above is the
        // known killer of the interactive edge-swipe-to-pop gesture on the
        // app's one shared `UINavigationController` — see
        // `PopGestureRestorer`'s doc comment for why and how this restores
        // it.
        .background(PopGestureRestorer())
        // Finding 8: the default `Spacing.xxl` inset sits inside the FAB's
        // band, so a toast (esp. the ~110-character signed-out edit
        // message) can overlap it. Constant inset — FAB height + its own
        // bottom padding + a gap — rather than FAB-visibility-conditional:
        // both `Bookings` and `Packing` render their own FAB in the same
        // band now (UX audit finding 5), so a toast that jumps position
        // per tab would be worse than one constant inset used everywhere.
        .toastOverlay($toast, bottomInset: Fab.scrollClearance)
        .onAppear {
            let id = tripId
            Task {
                await syncEngine?.observeTrip(id)
                await syncEngine?.schedulePullTrip(id)
            }
        }
        .onDisappear {
            let id = tripId
            Task { await syncEngine?.stopObservingTrip(id) }
        }
        .task {
            applyUITestAutopilotIfNeeded()
            if let initialToast {
                toast = initialToast
            }
        }
        .sheet(isPresented: $showUITestBookingDetail) {
            if let uitestBookingDetailItemId {
                NavigationStack { BookingDetailView(itemId: uitestBookingDetailItemId) }
            }
        }
        // Finding 5: if the profile the "Just mine" filter points at is
        // deleted (locally, or via a realtime pull that drops it), snap
        // back to "Everyone" instead of silently hiding the rest of the
        // trip behind a filter for a person who no longer exists.
        .onChange(of: tripProfiles.map(\.id)) { _, ids in
            selectedProfileFilter = PersonFilter.reconciledSelection(selectedProfileFilter, profileIds: Set(ids))
        }
    }

    /// M2 verify-drill autopilot — see the state vars' doc comment above.
    private func applyUITestAutopilotIfNeeded() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-uitestOpenBookings") {
            selectedTab = .bookings
        }
        if arguments.contains("-uitestOpenPacking") {
            selectedTab = .packing
        }
        if arguments.contains("-uitestOpenAdd") {
            isPresentingAdd = true
        }
        // M4 verify drill: selects the "Just mine" filter to the seeded
        // non-app "Meera" profile so the timeline/banner screenshot doesn't
        // depend on tapping a `PersonFilterBar` chip (no GUI tap automation
        // available in this environment).
        if arguments.contains("-uitestFilterToMeera"),
            let meera = tripProfiles.first(where: { $0.displayName.hasPrefix("Meera") }) {
            selectedProfileFilter = meera.id
        }
        if arguments.contains("-uitestOpenBookingDetail") {
            // Prefer a flight (the boarding-pass screenshot's whole point);
            // items sort by raw instant, so a same-UTC-day filler in
            // another zone can otherwise sort ahead of the outbound flight.
            let target = items.first(where: { $0.category == .flight && !($0.confirmation ?? "").isEmpty })
                ?? items.first(where: { !($0.confirmation ?? "").isEmpty })
            if let target {
                uitestBookingDetailItemId = target.id
                showUITestBookingDetail = true
            }
        }
        #endif
    }

    private func content(for trip: Trip) -> some View {
        VStack(spacing: 0) {
            hero(for: trip)

            if syncStatus.isOffline {
                SyncBanner()
            }
            if !syncStatus.syncIssues.isEmpty {
                SyncIssueBanner()
            }

            tabBar()

            if selectedTab == .itinerary, !tripProfiles.isEmpty {
                PersonFilterBar(chips: personFilterChips, selection: $selectedProfileFilter)
                if let selectedProfileFilter, let selectedProfileFirstName {
                    PersonFilterBanner(
                        personFirstName: selectedProfileFirstName,
                        summary: PersonFilter.summary(items, assignees: itemAssignees, selectedProfileId: selectedProfileFilter)
                    )
                }
            }

            ZStack(alignment: .bottomTrailing) {
                // Finding 5: all three tab views stay alive underneath —
                // see `tabContent(_:content:)`'s doc comment for why.
                ZStack {
                    tabContent(.itinerary) {
                        ItineraryTabView(
                            trip: trip,
                            items: filteredItems,
                            pendingRowIds: syncStatus.pendingRowIds,
                            myUserId: authManager.userId,
                            namesById: profileNames,
                            canEdit: canAddItems,
                            assigneesByItem: assigneesByItem,
                            filteredPersonName: selectedProfileFirstName,
                            toast: $toast,
                            isAwaitingFirstSync: awaitingFirstTripPull,
                            hasAnyItems: !items.isEmpty,
                            hiddenCountByDay: hiddenCountByDay
                        )
                    }
                    tabContent(.bookings) {
                        BookingsTabView(
                            items: items,
                            onAdd: canAddItems ? { isPresentingAdd = true } : nil,
                            isAwaitingFirstSync: awaitingFirstTripPull
                        )
                    }
                    tabContent(.packing) {
                        PackingListView(
                            tripId: trip.id,
                            tripCreatedBy: trip.createdBy,
                            isAwaitingFirstSync: awaitingFirstTripPull
                        )
                    }
                }

                // UX audit finding 5: FAB shows on Itinerary and Bookings —
                // Packing owns its own FAB (see `PackingListView`), so it's
                // excluded here rather than allow-listing just `.itinerary`.
                if canAddItems && selectedTab != .packing {
                    Fab { isPresentingAdd = true }
                        .padding(.trailing, Spacing.xl)
                        .padding(.bottom, Spacing.xxl)
                }
            }
        }
        .sheet(isPresented: $isPresentingAdd) {
            AddItemSheet(
                tripId: trip.id, tripTitle: trip.title, editing: nil,
                defaultZone: NewItemZoneDefault.zone(forExistingItemTzIdentifiers: items.map(\.tz)),
                tripStartDate: trip.startDate, tripCreatedBy: trip.createdBy
            ) { message in
                toast = message
            }
        }
        .sheet(isPresented: $isEditingTrip) {
            // UX audit finding 7: the context-menu-triggered edit path
            // through Home has its own toast (`HomeView`'s create/edit
            // sheets); this is the second entry point — the hero's pencil
            // button — so it needs the same "action keeps its name" close
            // ("Save changes" -> "Changes saved") via this screen's own
            // `$toast`/`.toastOverlay`.
            TripFormView(mode: .edit(trip)) { _, outcome in
                switch outcome {
                case .saved:
                    toast = "Changes saved"
                case .savedLocallyWhileSignedOut:
                    // Finding 5: same qualified toast as `HomeView`'s edit
                    // sheet, so this second entry point (the hero's pencil
                    // button) gives the identical honest signal.
                    toast = "Changes saved on this device \u{2014} you\u{2019}re signed out, so they " +
                        "won\u{2019}t sync until you sign back in."
                }
            }
        }
    }

    /// Finding 5: keeps all three tab views mounted underneath the visible
    /// one instead of the old `switch`-driven teardown, which was
    /// destroying and recreating `ItineraryTabView` (and its `@State
    /// hasAutoScrolledToToday`, and the `ScrollView`'s own scroll position)
    /// on every tab switch — a round trip through Bookings or Packing lost
    /// the traveler's place on the timeline and, worse, let the one-shot
    /// auto-scroll-to-today re-fire and yank them back to today on return.
    /// `.opacity` (not a conditional `if`) is what keeps the hidden views'
    /// state alive; `.allowsHitTesting`/`.accessibilityHidden` make sure a
    /// hidden tab's fields and buttons can't be focused or tapped while
    /// another tab is shown.
    private func tabContent<Content: View>(_ tab: Tab, @ViewBuilder content: () -> Content) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .accessibilityHidden(selectedTab != tab)
    }

    // MARK: - Hero (§4.2: gradient, glass back/share, city, meta)

    private func hero(for trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                GlassCircleButton(systemImage: "chevron.left", accessibilityLabel: "Back") {
                    dismiss()
                }
                Spacer()
                // Discoverable organizer edit entry point (finding 4): the
                // Home context menu's "Edit trip" is a shortcut, not the
                // sole route (HIG). Gated on the same `myRole` the FAB uses.
                if canEditTrip {
                    GlassCircleButton(systemImage: "pencil", accessibilityLabel: "Edit trip") {
                        isEditingTrip = true
                    }
                }
                // A `NavigationLink(value:)`, not a `GlassCircleButton`
                // action closure: `TripView` doesn't own the shared
                // `NavigationPath` (`HomeView` does), but a value-based
                // link pushes onto the nearest enclosing `NavigationStack`
                // regardless of nesting depth — same mechanism
                // `BookingsTabView`/`TimelineRowViews` already use for
                // `ItemRoute`. See `HomeView`'s `.navigationDestination(for:
                // ShareRoute.self)`.
                NavigationLink(value: ShareRoute(tripId: trip.id)) {
                    GlassCircleGlyph(systemImage: "square.and.arrow.up")
                }
                .accessibilityLabel("Share trip")
            }

            Spacer(minLength: Spacing.sm)

            Text(trip.title)
                .font(Typo.display(Typo.Size.display))
                .foregroundStyle(.white)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .fixedSize(horizontal: false, vertical: true)

            metaRow(for: trip)
                .padding(.top, Spacing.xs)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.lg)
        // Finding 2: `minHeight` (not a fixed `height`) so the hero grows
        // instead of clipping when Dynamic Type scales the title/meta —
        // the gradient background and scrim below are `.background`/
        // `.overlay`, so they scale with it for free.
        .frame(minHeight: 150, alignment: .bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            CoverGradient.from(key: trip.coverGradient)
                // Finding 3: swapped the flat 8%-black scrim for the same
                // bottom-anchored `textScrim` `TripCard` uses for the
                // identical white-text-on-gradient problem (clear until 35%
                // down, ramping to 45%-black at the bottom — see
                // `PaletteExtras.swift`). The hero's title/meta sit
                // bottom-anchored in the densest band: the meta row at
                // ~85% depth composites to ~4.5-5:1, the 30pt display title
                // at ~70% depth to ~4+:1 — clearing AA's 4.5:1 and 3:1
                // large-text bars respectively on all three gradients' worst
                // corners. The top-row glyph buttons no longer need this
                // scrim now that their own fill is `coverPillFill`.
                .overlay(CoverGradient.textScrim)
                .ignoresSafeArea(edges: .top)
        }
    }

    /// Finding 4 + 9b: two VoiceOver-distinct pieces instead of one run-on
    /// row of literal "·" fragments — dates/duration read as a single
    /// sentence, and the traveler count is a real tappable route (not just
    /// decorative text) to `ShareRoute`'s "who's coming" screen.
    private func metaRow(for trip: Trip) -> some View {
        HStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Text(dateRangeText(for: trip))
                metaDot
                Text("\(trip.durationInDays()) day\(trip.durationInDays() == 1 ? "" : "s")")
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                "\(accessibleDateRangeText(for: trip)), \(trip.durationInDays()) day\(trip.durationInDays() == 1 ? "" : "s")"
            )

            metaDot

            NavigationLink(value: ShareRoute(tripId: trip.id)) {
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "person.2.fill").font(.system(size: 10))
                    Text("\(max(tripProfiles.count, 1))")
                }
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xxs)
                .background(Palette.coverPillFill, in: Capsule())
                // Finding 4: the visual capsule (a `.background`, so it
                // doesn't grow with the frame) was rendering under 44pt
                // wide — `minWidth` added alongside the existing
                // `minHeight` so the hit target meets the 44pt floor on
                // both axes; `.contentShape(Rectangle())` below already
                // extends hit-testing to the enlarged frame, which only
                // borders non-interactive text.
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .accessibilityLabel("\(max(tripProfiles.count, 1)) traveler\(max(tripProfiles.count, 1) == 1 ? "" : "s")")
            .accessibilityHint("Manage people and invites")
        }
        .font(Typo.body(Typo.Size.caption))
        .foregroundStyle(.white.opacity(0.92))
    }

    private var metaDot: some View {
        Text("·").opacity(0.6)
            .accessibilityHidden(true)
    }

    /// Finding 5: delegates to `TripDateRangeFormat` so a trip outside the
    /// current year (or spanning two) shows a year instead of the old
    /// always-year-less "Mar 14 – Mar 20."
    private func dateRangeText(for trip: Trip) -> String {
        TripDateRangeFormat.text(start: trip.startDate, end: trip.endDate)
    }

    /// Same rules as `dateRangeText`, joined with a spoken "to" instead of
    /// the visual en-dash — VoiceOver reads punctuation like "–" and "·"
    /// as literal fragments, not implied connectors (finding 9b).
    private func accessibleDateRangeText(for trip: Trip) -> String {
        TripDateRangeFormat.spokenText(start: trip.startDate, end: trip.endDate)
    }

    // MARK: - Sub-tabs (Itinerary · Bookings only — Map/$ Split hidden, §9.4)

    /// The three content tabs — Itinerary · Bookings · Packing — each swapping
    /// `selectedTab` in place. Packing was originally a separate pushed screen
    /// reached from a "button" in this row; it's now a peer tab so all three
    /// behave consistently (they read as tabs, so they should act as tabs).
    private func tabBar() -> some View {
        Group {
            // Finding 4: a fixed `HStack` truncates the labels unreadably at
            // accessibility sizes (`TripCard.swift`'s established
            // `isAccessibilitySize` convention) — this branches to a
            // horizontal scroll row there instead, exactly like
            // `PersonFilterBar`'s row. Non-AX rendering below is untouched.
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.xl) { tabButtons }
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: Spacing.xl) {
                    tabButtons
                    Spacer()
                }
            }
        }
        .padding(.horizontal, Spacing.xl)
        // Finding 9a: `.isTabBar` (iOS 17+, matches this app's SwiftData/
        // @Observable baseline) so VoiceOver announces tab role and "tab N
        // of M" position; `.contain` groups the row as one navigable unit
        // rather than three unrelated static elements.
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.mist).frame(height: 1)
        }
    }

    @ViewBuilder
    private var tabButtons: some View {
        ForEach(Tab.allCases, id: \.self) { tab in
            Button {
                if reduceMotion {
                    selectedTab = tab
                } else {
                    withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab }
                }
            } label: {
                // Finding 1a: `minHeight: 44` (not the HStack's old
                // `.padding(.top, Spacing.md)`) so the full 44pt column
                // is hit-testable while the text+underline stay
                // bottom-aligned exactly where they render today — the
                // padding's ~12pt of headroom is absorbed into this
                // frame instead.
                VStack(spacing: Spacing.sm) {
                    Text(tab.rawValue)
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(selectedTab == tab ? Palette.ink : Palette.slate)
                    ZStack {
                        Color.clear.frame(height: 2)
                        if selectedTab == tab {
                            RoundedRectangle(cornerRadius: 1)
                                .fill(Palette.amber)
                                .frame(height: 2)
                                .matchedGeometryEffect(id: "tab-underline", in: tabUnderline)
                        }
                    }
                }
                .frame(minHeight: 44, alignment: .bottom)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
        }
    }

    // MARK: - Derived

    /// updated_by → display name, for the "edited by {name}" chip. Checks
    /// account profiles first, then trip profiles linked to that user.
    private var profileNames: [UUID: String] {
        var names: [UUID: String] = [:]
        for profile in tripProfiles {
            if let linked = profile.linkedUserId {
                names[linked] = profile.displayName
            }
        }
        for profile in profiles {
            names[profile.id] = profile.displayName
        }
        return names
    }

    // MARK: - "Just mine" (BUILD_PLAN.md §5.4)

    /// `items` scoped to `selectedProfileFilter` — see `PersonFilter`'s doc
    /// comment for the "no assignees = for everyone" rule.
    ///
    /// Reconciles the selection defensively (finding 5) rather than trusting
    /// `selectedProfileFilter` outright: `.onChange(of: tripProfiles...)`
    /// handles the steady-state reset, but a single frame between a
    /// profile's deletion and that `onChange` firing could otherwise render
    /// a stale-filtered (effectively empty-for-everyone-else) list.
    private var filteredItems: [ItineraryItem] {
        PersonFilter.filteredItems(items, assignees: itemAssignees, selectedProfileId: reconciledProfileFilter)
    }

    /// UX audit finding 1: how many items each day's "Just mine" filter is
    /// currently hiding, keyed by `DayDate.stringValue` (==
    /// `TimelineDayModel.id`) — lets `ItineraryTabView` tell a genuinely
    /// free day apart from a day that's actually full for everyone else.
    private var hiddenCountByDay: [String: Int] {
        guard let trip else { return [:] }
        return PersonFilter.hiddenDayCounts(
            items, assignees: itemAssignees, selectedProfileId: reconciledProfileFilter,
            tripStart: DayDate.from(trip.startDate, calendar: .current)
        )
    }

    /// Finding 5's stale-selection guard, shared by `filteredItems` and
    /// `hiddenCountByDay` so it's computed once per render pass instead of
    /// twice.
    private var reconciledProfileFilter: UUID? {
        PersonFilter.reconciledSelection(selectedProfileFilter, profileIds: Set(tripProfiles.map(\.id)))
    }

    /// `itemId` -> resolved assignee avatars, for `ItineraryTabView`'s
    /// per-card `AvatarStack`. Scoped to `items`' own ids since
    /// `itemAssignees` is an unfiltered query (`ItemAssignee` has no
    /// `tripId` of its own).
    private var assigneesByItem: [UUID: [AvatarStack.Person]] {
        let idsByItem = PersonFilter.assigneeProfileIds(itemAssignees, itemIds: Set(items.map(\.id)))
        let profilesById = Dictionary(uniqueKeysWithValues: tripProfiles.map { ($0.id, $0) })
        return idsByItem.mapValues { profileIds in
            profileIds.compactMap { id -> AvatarStack.Person? in
                guard let profile = profilesById[id] else { return nil }
                return AvatarStack.Person(id: profile.id, initial: initials(from: profile.displayName), colorName: profile.avatarColor)
            }
        }
    }

    /// Finding F12: the viewer's own linked profile sorts first — before,
    /// "Just mine" was scattered wherever `createdAt` happened to place it,
    /// so a traveler filtering to themself had to scan the whole row first.
    /// Everything else keeps the existing `createdAt` order; the
    /// "Everyone" chip's own position is `PersonFilterBar`'s, untouched.
    private var personFilterChips: [PersonFilterBar.Chip] {
        let sorted = tripProfiles.sorted { $0.createdAt < $1.createdAt }
        // `linkedUserId == nil` means "not an app user" (§3.3) — must not
        // match a signed-out `authManager.userId == nil` as "mine".
        let isMine: (TripProfile) -> Bool = { profile in
            guard let userId = authManager.userId, let linkedUserId = profile.linkedUserId else { return false }
            return linkedUserId == userId
        }
        let mine = sorted.filter(isMine)
        let others = sorted.filter { !isMine($0) }
        return (mine + others).map { profile in
            PersonFilterBar.Chip(
                id: profile.id,
                firstName: firstName(from: profile.displayName),
                initial: initials(from: profile.displayName),
                colorName: profile.avatarColor
            )
        }
    }

    private var selectedProfileFirstName: String? {
        guard let selectedProfileFilter else { return nil }
        guard let profile = tripProfiles.first(where: { $0.id == selectedProfileFilter }) else { return nil }
        return firstName(from: profile.displayName)
    }

    private func firstName(from displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    private func initials(from displayName: String) -> String {
        firstName(from: displayName).prefix(1).uppercased()
    }

    /// Finding 3: the old bare-amber-text "Back to trips" button was both
    /// under AA contrast (~2.3:1 amber-on-paper) and under the 44pt hit
    /// target. Restyled as the same filled-amber capsule CTA
    /// `BookingsTabView`'s empty state uses, and the heading now explains
    /// *why* — §6.6 voice: name the likely cause, then point at where the
    /// traveler's other trips still are.
    private var missingTripState: some View {
        VStack(spacing: Spacing.md) {
            Text("This trip is no longer available")
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.ink)
            Text(
                "It may have been removed by the organizer, or your access may have ended. " +
                    "Your other trips are still on your trips list."
            )
            .font(Typo.body())
            .foregroundStyle(Palette.slate)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xxl)
            Button(action: { dismiss() }) {
                Text("Back to trips")
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
    }
}
