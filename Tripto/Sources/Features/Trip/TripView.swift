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
    private var canAddItems: Bool { myRole != .viewer }

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            if let trip {
                content(for: trip)
            } else {
                missingTripState
            }
        }
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .toastOverlay($toast)
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
                switch selectedTab {
                case .itinerary:
                    ItineraryTabView(
                        trip: trip,
                        items: filteredItems,
                        pendingRowIds: syncStatus.pendingRowIds,
                        myUserId: authManager.userId,
                        namesById: profileNames,
                        canEdit: canAddItems,
                        assigneesByItem: assigneesByItem,
                        filteredPersonName: selectedProfileFirstName,
                        toast: $toast
                    )
                case .bookings:
                    BookingsTabView(items: items)
                case .packing:
                    PackingListView(tripId: trip.id)
                }

                if canAddItems && selectedTab == .itinerary {
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
                tripStartDate: trip.startDate
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
            TripFormView(mode: .edit(trip)) { _ in toast = "Changes saved" }
        }
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
                if myRole == .organizer {
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
                .lineLimit(1)

            HStack(spacing: Spacing.sm) {
                Text(dateRangeText(for: trip))
                metaDot
                Text("\(trip.durationInDays()) day\(trip.durationInDays() == 1 ? "" : "s")")
                metaDot
                HStack(spacing: Spacing.xxs) {
                    Image(systemName: "person.2.fill").font(.system(size: 10))
                    Text("\(max(tripProfiles.count, 1))")
                }
            }
            .font(Typo.body(Typo.Size.caption))
            .foregroundStyle(.white.opacity(0.92))
            .padding(.top, Spacing.xs)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.lg)
        .frame(height: 150, alignment: .bottom)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            CoverGradient.from(key: trip.coverGradient)
                .overlay(Color.black.opacity(0.08)) // contrast scrim (§7.3)
                .ignoresSafeArea(edges: .top)
        }
    }

    private var metaDot: some View {
        Text("·").opacity(0.6)
    }

    private func dateRangeText(for trip: Trip) -> String {
        let start = trip.startDate.formatted(.dateTime.month(.abbreviated).day())
        let end = trip.endDate.formatted(.dateTime.month(.abbreviated).day())
        return "\(start) – \(end)"
    }

    // MARK: - Sub-tabs (Itinerary · Bookings only — Map/$ Split hidden, §9.4)

    /// The three content tabs — Itinerary · Bookings · Packing — each swapping
    /// `selectedTab` in place. Packing was originally a separate pushed screen
    /// reached from a "button" in this row; it's now a peer tab so all three
    /// behave consistently (they read as tabs, so they should act as tabs).
    private func tabBar() -> some View {
        HStack(spacing: Spacing.xl) {
            ForEach(Tab.allCases, id: \.self) { tab in
                Button {
                    if reduceMotion {
                        selectedTab = tab
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { selectedTab = tab }
                    }
                } label: {
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
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selectedTab == tab ? [.isSelected] : [])
            }
            Spacer()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.mist).frame(height: 1)
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
    private var filteredItems: [ItineraryItem] {
        PersonFilter.filteredItems(items, assignees: itemAssignees, selectedProfileId: selectedProfileFilter)
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

    private var personFilterChips: [PersonFilterBar.Chip] {
        tripProfiles
            .sorted { $0.createdAt < $1.createdAt }
            .map { profile in
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

    private var missingTripState: some View {
        VStack(spacing: Spacing.md) {
            Text("This trip is no longer available")
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.slate)
            Button("Back to trips") { dismiss() }
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.amber)
        }
    }
}
