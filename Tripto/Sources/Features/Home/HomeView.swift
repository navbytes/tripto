import SwiftData
import SwiftUI

/// Home / trip list (BUILD_PLAN.md §4.1). Renders straight from the local
/// SwiftData mirror via `@Query` — no awaiting the network (SYNC_DESIGN.md
/// Principle 1) — while `SyncEngine` pulls/pushes in the background and
/// `SyncStatus` drives the offline banner and per-card pending chips.
struct HomeView: View {
    @Query(sort: \Trip.startDate) private var trips: [Trip]
    @Query private var profiles: [Profile]
    @Query private var tripMembers: [TripMember]
    @Query private var tripProfiles: [TripProfile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(SyncStatus.self) private var syncStatus
    @Environment(AppRouter.self) private var appRouter

    @State private var selectedTab = "Upcoming"
    @State private var isPresentingCreate = false
    @State private var editingTrip: Trip?
    @State private var tripPendingDeletion: Trip?
    /// M3: surfaces `AppRouter.errorToast` (an expired/revoked invite link)
    /// as a persistent `.alert` rather than a toast (finding 6) — a
    /// two-second auto-dismissing toast can be missed entirely, and this is
    /// the one Home error worth blocking on. Nothing else on Home toasts.
    @State private var inviteErrorMessage: String?
    /// The app's one `NavigationPath` (`TripView.swift`'s doc comment: "the
    /// one `NavigationStack` rooted in `HomeView`") — pushing `TripRoute`/
    /// `ItemRoute` values onto this, rather than wrapping each row in a
    /// `NavigationLink`, is also what keeps a trip card's disclosure
    /// chevron from appearing: `List` only draws that accessory for a
    /// `NavigationLink`-shaped row, never for a plain `Button`.
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                Palette.paper.ignoresSafeArea()

                VStack(spacing: 0) {
                    if syncStatus.isOffline {
                        SyncBanner()
                    }
                    if !syncStatus.syncIssues.isEmpty {
                        SyncIssueBanner()
                    }
                    // The empty-trips case is covered by `initialLoadState`
                    // below, so this only needs to fire once there's
                    // already a list to sit above (finding 6).
                    if appRouter.isJoiningTrip && !trips.isEmpty {
                        joiningTripBanner
                    }

                    header
                        .padding(.horizontal, Spacing.xl)
                        .padding(.top, Spacing.md)
                        .padding(.bottom, Spacing.sm)

                    // Hidden while trips is empty (finding 9) — an inert
                    // Upcoming/Past toggle over a single empty/loading
                    // message isn't a real choice yet.
                    if !trips.isEmpty {
                        SegmentedControl(options: ["Upcoming", "Past"], selection: $selectedTab)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.bottom, Spacing.xs)
                    }

                    if trips.isEmpty {
                        // First-pull loading vs. genuinely-empty account
                        // (finding 2): `hasCompletedInitialHomePull` is the
                        // only way to tell them apart the first time Home
                        // ever mounts this session.
                        if appRouter.isJoiningTrip || (!syncStatus.hasCompletedInitialHomePull && !syncStatus.isOffline) {
                            initialLoadState
                        } else {
                            emptyState
                        }
                    } else if visibleTrips.isEmpty {
                        emptyTabState
                    } else {
                        tripList
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            // The one route-based nav stack (`TripView.swift`'s doc
            // comment): Home pushes `TripRoute`; `TripView`'s own tabs push
            // `ItemRoute` onto this same stack to reach `BookingDetailView`.
            .navigationDestination(for: TripRoute.self) { route in
                TripView(tripId: route.id, initialToast: route.welcomeToast)
            }
            .navigationDestination(for: ItemRoute.self) { route in
                BookingDetailView(itemId: route.id)
            }
            .navigationDestination(for: ShareRoute.self) { route in
                ShareTripView(tripId: route.tripId)
            }
            .navigationDestination(for: SettingsRoute.self) { _ in
                SettingsView()
            }
            .toolbar {
                #if DEBUG
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Button("Seed demo trip") {
                            Task { await DemoSeeder.seed(modelContext: modelContext, syncEngine: syncEngine, authManager: authManager) }
                        }
                        Button("Reset local cache (re-pull)") {
                            Task { await syncEngine?.resetLocalStore() }
                        }
                        Button("Sign out", role: .destructive) {
                            Task { await authManager.signOut() }
                        }
                    } label: {
                        Image(systemName: "ladybug")
                    }
                }
                #endif
            }
            .sheet(isPresented: $isPresentingCreate) {
                TripFormView(mode: .create)
            }
            .sheet(item: $editingTrip) { trip in
                TripFormView(mode: .edit(trip))
            }
            .confirmationDialog(
                "Delete trip",
                isPresented: Binding(
                    get: { tripPendingDeletion != nil },
                    set: { isPresented in if !isPresented { tripPendingDeletion = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Delete trip", role: .destructive) {
                    if let trip = tripPendingDeletion { delete(trip) }
                    tripPendingDeletion = nil
                }
                Button("Cancel", role: .cancel) { tripPendingDeletion = nil }
            } message: {
                if let trip = tripPendingDeletion {
                    Text("This removes \u{201C}\(trip.title)\u{201D} and everything in it for everyone on the trip.")
                }
            }
            .task {
                // Real product behavior (M3), not test autopilot: claims a
                // token stashed by `AppRouter.handleIncoming` while signed
                // out, now that Home mounting proves a session exists.
                await appRouter.claimPendingInviteIfNeeded()
                await applyUITestAutopilotIfNeeded()
            }
            .onChange(of: appRouter.tripToOpen) { _, tripId in
                guard let tripId else { return }
                Task {
                    await syncEngine?.pullHome()
                    // A direct fetch, not the reactive `@Query` array —
                    // avoids depending on how quickly `@Query` re-renders
                    // after another context's save (SwiftData cross-context
                    // change notification isn't guaranteed synchronous with
                    // the awaited `pullHome()` above returning).
                    let descriptor = FetchDescriptor<Trip>(predicate: #Predicate<Trip> { $0.id == tripId })
                    let title = (try? modelContext.fetch(descriptor))?.first?.title
                    path.append(TripRoute(id: tripId, welcomeToast: "You\u{2019}re in \u{2014} welcome to \(title ?? "the trip")"))
                    appRouter.clearTripToOpen()
                }
            }
            .onChange(of: appRouter.errorToast) { _, message in
                guard let message else { return }
                inviteErrorMessage = message
                appRouter.clearErrorToast()
            }
            .alert(
                "Couldn\u{2019}t join trip",
                isPresented: Binding(
                    get: { inviteErrorMessage != nil },
                    set: { isPresented in if !isPresented { inviteErrorMessage = nil } }
                )
            ) {
                Button("OK") {}
            } message: {
                Text(inviteErrorMessage ?? "")
            }
        }
    }

    /// M2/M3 verify-drill autopilot (see `WelcomeView`'s matching hook) —
    /// seeds the demo trip and/or navigates straight into it (and, for M3,
    /// into Share/Settings, or simulates `.onOpenURL`) when launched with
    /// the matching DEBUG flags, so the screenshot pass doesn't depend on
    /// GUI tap automation. Idempotent across relaunches of the same
    /// simulator: seeding only runs `if trips.isEmpty`, so a second launch
    /// against already-seeded data just navigates.
    private func applyUITestAutopilotIfNeeded() async {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        guard authManager.isSignedIn else { return }

        // Verify-drill only: sign out so a launch can reach the (signed-out)
        // WelcomeView — e.g. to screenshot the pre-sign-in invite preview.
        if arguments.contains("-uitestSignOut") {
            await authManager.signOut()
            return
        }

        // Simulates a real `.onOpenURL` delivery for the verify drill's
        // two-user claim phase (`xcrun simctl openurl` reaches the real
        // `.onOpenURL` directly; this flag exists only for a launch where
        // that's inconvenient to sequence, e.g. handing the URL in at the
        // same moment as sign-in). Format: `-uitestOpenURL <url-string>`.
        if let index = arguments.firstIndex(of: "-uitestOpenURL"), index + 1 < arguments.count,
            let url = URL(string: arguments[index + 1]) {
            appRouter.handleIncoming(url: url, isSignedIn: authManager.isSignedIn)
        }

        var targetTripId = trips.first?.id
        if arguments.contains("-uitestSeedIfEmpty"), trips.isEmpty {
            targetTripId = await DemoSeeder.seed(modelContext: modelContext, syncEngine: syncEngine, authManager: authManager)
        }
        if arguments.contains("-uitestOpenFirstTrip"), let targetTripId, path.isEmpty {
            path.append(TripRoute(id: targetTripId))
        }
        if arguments.contains("-uitestOpenShare"), let targetTripId, path.count == 1 {
            path.append(ShareRoute(tripId: targetTripId))
        }
        // Packing is a TripView tab now (see TripView's `-uitestOpenPacking`),
        // reached by opening the trip, not a pushed route from Home.
        if arguments.contains("-uitestOpenSettings"), path.isEmpty {
            path.append(SettingsRoute())
        }
        #endif
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting)
                    .font(Typo.body(weight: .medium))
                    .foregroundStyle(Palette.slate)
                Text("Your trips")
                    .font(Typo.display())
                    .foregroundStyle(Palette.ink)
            }
            Spacer()
            // NavigationLink(value:), same reasoning as TripView's share
            // button: pushes SettingsRoute onto this stack (M3 brief:
            // "Reachable from HomeView (avatar tap → Settings)").
            NavigationLink(value: SettingsRoute()) {
                Circle()
                    .fill(Palette.indigo)
                    .frame(width: 42, height: 42)
                    .overlay {
                        Text(initials(from: myProfile?.displayName ?? "Traveler"))
                            .font(Typo.display(16))
                            .foregroundStyle(.white)
                    }
                    // 44pt hit target (§6.5) around the 42pt visual circle —
                    // finding 8.
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Settings")
        }
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let period: String
        switch hour {
        case 0..<12: period = "morning"
        case 12..<17: period = "afternoon"
        default: period = "evening"
        }
        let firstName = firstName(from: myProfile?.displayName ?? "Traveler")
        return "Good \(period), \(firstName)"
    }

    private var myProfile: Profile? {
        guard let userId = authManager.userId else { return nil }
        return profiles.first { $0.id == userId }
    }

    // MARK: - List

    private var tripList: some View {
        List {
            ForEach(visibleTrips) { trip in
                Button {
                    path.append(TripRoute(id: trip.id))
                } label: {
                    TripCard(
                        trip: trip,
                        people: people(for: trip),
                        isPending: syncStatus.pendingRowIds.contains(trip.id)
                    )
                    .padding(.horizontal, Spacing.xl)
                }
                .buttonStyle(.plain)
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.bottom, Spacing.lg)
                .swipeActions(edge: .trailing) {
                    if isOrganizer(of: trip) {
                        Button("Delete", role: .destructive) {
                            tripPendingDeletion = trip
                        }
                    }
                }
                .contextMenu {
                    if isOrganizer(of: trip) {
                        Button("Edit trip") { editingTrip = trip }
                        Button("Delete trip", role: .destructive) {
                            tripPendingDeletion = trip
                        }
                    }
                }
            }

            planNewTripRow
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        // User-initiated escape hatch for a missed realtime event (finding
        // 10) — realtime/debounced pulls are the normal path, this is just
        // the fallback.
        .refreshable { await syncEngine?.pullHome() }
    }

    private var planNewTripRow: some View {
        Button {
            isPresentingCreate = true
        } label: {
            HStack {
                Spacer()
                Label("Plan a new trip", systemImage: "plus")
                    .font(Typo.body(weight: .semibold))
                Spacer()
            }
            .foregroundStyle(Palette.slate)
            .padding(.vertical, Spacing.lg)
            .background {
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .strokeBorder(Palette.mist, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
            }
            .padding(.horizontal, Spacing.xl)
        }
        .buttonStyle(.plain)
    }

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Spacer()
                Image(systemName: "airplane.departure")
                    .font(.system(size: 40))
                    .foregroundStyle(Palette.amber)
                VStack(spacing: Spacing.xs) {
                    Text("Plan your first trip")
                        .font(Typo.display(Typo.Size.title))
                        .foregroundStyle(Palette.ink)
                    Text("Everyone\u{2019}s bookings in one shared, at-a-glance itinerary.")
                        .font(Typo.body())
                        .foregroundStyle(Palette.slate)
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    valueRow("clock", "Every flight and plan in its own local time")
                    valueRow("person.2", "Invite family \u{2014} or share a link, no app needed")
                    valueRow("suitcase", "A shared packing list, and \u{201C}just mine\u{201D} per person")
                }
                .padding(.top, Spacing.xs)
                planNewTripCTA
                    .padding(.top, Spacing.xs)
                Spacer()
                Spacer()
            }
            .padding(Spacing.xl)
            .containerRelativeFrame(.vertical)
        }
        // A just-invited user staring at an empty Home needs the same pull
        // escape hatch as the populated list (finding 10).
        .refreshable { await syncEngine?.pullHome() }
    }

    private func valueRow(_ icon: String, _ text: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Palette.amber)
                .frame(width: 20)
            Text(text)
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
        }
    }

    /// Shown when the *selected tab* is empty but the other tab has trips —
    /// avoids a near-blank screen with only a lone dashed button.
    private var emptyTabState: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                Spacer()
                Text(selectedTab == "Upcoming" ? "No upcoming trips" : "No past trips yet")
                    .font(Typo.display(Typo.Size.title))
                    .foregroundStyle(Palette.ink)
                Text(selectedTab == "Upcoming"
                     ? "Plan the next one \u{2014} everyone\u{2019}s bookings in one shared itinerary."
                     : "Trips you\u{2019}ve wrapped up will show up here.")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Spacing.xl)
                if selectedTab == "Upcoming" {
                    planNewTripCTA.padding(.top, Spacing.xs)
                }
                Spacer()
                Spacer()
            }
            .padding(Spacing.xl)
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await syncEngine?.pullHome() }
    }

    /// First-pull loading placeholder (finding 2) — shown while a
    /// genuinely-empty account can't yet be told apart from "haven't heard
    /// from the server yet," and while an invite claim is in flight for a
    /// brand-new account (finding 6's empty-trips case).
    private var initialLoadState: some View {
        ScrollView {
            VStack(spacing: Spacing.md) {
                Spacer()
                ProgressView()
                Text(appRouter.isJoiningTrip ? "Joining trip\u{2026}" : "Checking for your trips\u{2026}")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
                Spacer()
                Spacer()
            }
            .padding(Spacing.xl)
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await syncEngine?.pullHome() }
    }

    /// Slim in-progress indicator for an invite claim (finding 6) — shown
    /// only once there's already a list to sit above; the empty-trips case
    /// is covered by `initialLoadState`.
    private var joiningTripBanner: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
            Text("Joining trip\u{2026}")
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(Palette.amberSoft)
    }

    private var planNewTripCTA: some View {
        Button {
            isPresentingCreate = true
        } label: {
            Text("Plan a new trip")
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.onAmber)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.md)
                .background(Palette.amber, in: Capsule())
        }
    }

    // MARK: - Derived data

    private var upcomingTrips: [Trip] {
        trips
            .filter { !$0.bucket().isPastTab }
            .sorted { lhs, rhs in
                let lhsInProgress = lhs.bucket() == .inProgress
                let rhsInProgress = rhs.bucket() == .inProgress
                if lhsInProgress != rhsInProgress { return lhsInProgress }
                return lhs.startDate < rhs.startDate
            }
    }

    private var pastTrips: [Trip] {
        trips.filter { $0.bucket().isPastTab }.sorted { $0.startDate > $1.startDate }
    }

    private var visibleTrips: [Trip] {
        selectedTab == "Upcoming" ? upcomingTrips : pastTrips
    }

    private func people(for trip: Trip) -> [AvatarStack.Person] {
        tripProfiles
            .filter { $0.tripId == trip.id }
            .sorted { $0.createdAt < $1.createdAt }
            .map { profile in
                AvatarStack.Person(
                    id: profile.id,
                    initial: initials(from: profile.displayName),
                    colorName: profile.avatarColor
                )
            }
    }

    private func isOrganizer(of trip: Trip) -> Bool {
        guard let userId = authManager.userId else { return false }
        return tripMembers.contains {
            $0.tripId == trip.id && $0.userId == userId && $0.role == .organizer
        }
    }

    private func firstName(from displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    private func initials(from displayName: String) -> String {
        firstName(from: displayName).prefix(1).uppercased()
    }

    // MARK: - Mutations

    private func delete(_ trip: Trip) {
        let tripId = trip.id
        modelContext.delete(trip)
        // Local cascade mirrors the server's FK cascade (SYNC_DESIGN.md
        // "Write paths") — anything already pulled for this trip goes with
        // it rather than lingering as an orphan until the next pull.
        for member in tripMembers where member.tripId == tripId {
            modelContext.delete(member)
        }
        for profile in tripProfiles where profile.tripId == tripId {
            modelContext.delete(profile)
        }
        try? modelContext.save()
        Task { await syncEngine?.enqueueDelete(table: .trips, rowId: tripId, tripId: tripId) }
    }
}
