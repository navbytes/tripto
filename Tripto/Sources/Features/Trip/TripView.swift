import SwiftData
import SwiftUI

/// Value routes for the one `NavigationStack` (rooted in `HomeView`).
/// Distinct wrapper types — not bare `UUID`s — so trip and item
/// destinations can't collide in the same path.
struct TripRoute: Hashable {
    let id: UUID
}

struct ItemRoute: Hashable {
    let id: UUID
}

/// The trip screen (BUILD_PLAN.md §4.2 — THE core screen): cover-gradient
/// hero, Itinerary · Bookings sub-tabs (Map/$ Split hidden per §9.4), and
/// the day-grouped timeline. Renders entirely from the local SwiftData
/// mirror; `onAppear`/`onDisappear` drive the per-trip realtime channel and
/// debounced pull (SYNC_DESIGN.md "Realtime").
struct TripView: View {
    let tripId: UUID

    @Query private var trips: [Trip]
    @Query private var items: [ItineraryItem]
    @Query private var members: [TripMember]
    @Query private var tripProfiles: [TripProfile]
    @Query private var profiles: [Profile]

    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(SyncStatus.self) private var syncStatus
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var selectedTab: Tab = .itinerary
    @State private var isPresentingAdd = false
    @State private var toast: String?
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
    }

    init(tripId: UUID) {
        self.tripId = tripId
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
        .task { applyUITestAutopilotIfNeeded() }
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
        if arguments.contains("-uitestOpenAdd") {
            isPresentingAdd = true
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

            tabBar

            ZStack(alignment: .bottomTrailing) {
                switch selectedTab {
                case .itinerary:
                    ItineraryTabView(
                        trip: trip,
                        items: items,
                        pendingRowIds: syncStatus.pendingRowIds,
                        myUserId: authManager.userId,
                        namesById: profileNames,
                        canEdit: canAddItems,
                        toast: $toast
                    )
                case .bookings:
                    BookingsTabView(items: items)
                }

                if canAddItems && selectedTab == .itinerary {
                    Fab { isPresentingAdd = true }
                        .padding(.trailing, Spacing.xl)
                        .padding(.bottom, Spacing.xxl)
                }
            }
        }
        .sheet(isPresented: $isPresentingAdd) {
            AddItemSheet(tripId: trip.id, tripTitle: trip.title, editing: nil) { message in
                toast = message
            }
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
                GlassCircleButton(systemImage: "square.and.arrow.up", accessibilityLabel: "Share trip") {
                    // No dead-end silence (§9.4 spirit): sharing is M3.
                    toast = "Sharing lands in M3"
                }
            }

            Spacer(minLength: Spacing.sm)

            Text(trip.title)
                .font(Typo.display(Typo.Size.display))
                .foregroundStyle(.white)
                .lineLimit(1)

            HStack(spacing: Spacing.sm) {
                Text(dateRangeText(for: trip))
                metaDot
                Text("\(trip.durationInDays()) days")
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

    private var tabBar: some View {
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
