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
    /// the one Home error worth blocking on. The refresh-failure toast below
    /// is the deliberate exception: it's advisory, not blocking, and scoped
    /// to the pull-to-refresh gesture that triggered it (finding 1).
    @State private var inviteErrorMessage: String?
    /// Finding 1 (refresh-scoped gap): a manual pull-to-refresh that fails
    /// silently leaves the list unchanged with no feedback. Driven by
    /// `HomeRefreshFeedback.shouldToastAfterRefresh` from `refreshFromPull()`
    /// so all six `.refreshable` closures share one gated path. Also carries
    /// the create/edit sheets' "Trip created"/"Changes saved" confirmations
    /// (UX audit finding 7) — one general-purpose toast slot, not a
    /// dedicated one per source.
    @State private var toast: String?
    /// Finding 1 (silent retry): `pullFailedState`'s "Try again" button
    /// re-entering an in-flight pull with no feedback and no protection
    /// against a double-tap. Kept local to `HomeView` rather than widening
    /// `SyncStatus` with an in-flight flag — this button is the only
    /// consumer.
    @State private var isRetryingPull = false
    /// Set once a manual retry from `pullFailedState` comes back failed
    /// again (see `HomeRefreshFeedback.shouldNoteRetryFailure`); drives the
    /// inline "still couldn't reach the server" caption under the button.
    @State private var retryFailedAgain = false
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
                        // First-pull loading vs. genuinely-empty vs.
                        // pull-failed account (findings 1/2): the resolver
                        // is the only place this decision table lives now,
                        // so the regression tests on it are the safety net.
                        switch HomeEmptyPlaceholder.resolve(
                            isJoiningTrip: appRouter.isJoiningTrip,
                            hasCompletedInitialHomePull: syncStatus.hasCompletedInitialHomePull,
                            lastHomePullFailed: syncStatus.lastHomePullFailed,
                            isOffline: syncStatus.isOffline
                        ) {
                        case .joining, .initialLoad:
                            initialLoadState
                        case .offlineFirstLoad:
                            offlineFirstLoadState
                        case .pullFailed:
                            pullFailedState
                        case .empty:
                            emptyState
                        }
                    } else if visibleTrips.isEmpty {
                        emptyTabState
                    } else {
                        tripList
                    }
                }
            }
            .toastOverlay($toast)
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
                // Finding 2: switches to whichever tab the saved trip
                // actually files under — `bucket().isPastTab`, not a
                // hardcoded "Upcoming", so a backdated trip still lands
                // somewhere visible.
                TripFormView(mode: .create) { trip, _ in
                    // Create-mode always reports `.saved` — it hard-stops on
                    // a nil `userId` before ever reaching a save.
                    selectedTab = trip.bucket().isPastTab ? "Past" : "Upcoming"
                    toast = "Trip created"
                }
            }
            .sheet(item: $editingTrip) { trip in
                // Same fix, symmetric case: editing a trip's dates can move
                // it to the other tab, where it'd otherwise vanish.
                TripFormView(mode: .edit(trip)) { savedTrip, outcome in
                    selectedTab = savedTrip.bucket().isPastTab ? "Past" : "Upcoming"
                    switch outcome {
                    case .saved:
                        toast = "Changes saved"
                    case .savedLocallyWhileSignedOut:
                        // Finding 5: the write already happened locally —
                        // this just makes the toast honest about it not
                        // syncing yet (§6.6: what happened + how to fix it).
                        toast = "Changes saved on this device \u{2014} you\u{2019}re signed out, so they " +
                            "won\u{2019}t sync until you sign back in."
                    }
                }
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

    /// Shared path for all six `.refreshable { }` closures on Home (finding
    /// 1) — routes every pull-to-refresh gesture through the same gate so
    /// they can't diverge. `pullHome()` itself already drives `SyncStatus`;
    /// this only decides whether *this* gesture, specifically, should also
    /// toast. Known accepted edge: a refresh landing while a debounced pull
    /// is already in flight early-returns from `pullHome()` and reads the
    /// previous attempt's flag — rare, and the resulting message stays
    /// truthful either way.
    private func refreshFromPull() async {
        await syncEngine?.pullHome()
        if HomeRefreshFeedback.shouldToastAfterRefresh(
            lastHomePullFailed: syncStatus.lastHomePullFailed,
            isOffline: syncStatus.isOffline,
            hasTrips: !trips.isEmpty
        ) {
            toast = "Couldn\u{2019}t refresh \u{2014} pull to try again"
        }
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
                    .accessibilityAddTraits(.isHeader)
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
                        Button("Delete trip", role: .destructive) {
                            tripPendingDeletion = trip
                        }
                    }
                }
                .modifier(OrganizerTripMenu(
                    isOrganizer: isOrganizer(of: trip),
                    onEdit: { editingTrip = trip },
                    onDelete: { tripPendingDeletion = trip }
                ))
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
        .refreshable { await refreshFromPull() }
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
        .refreshable { await refreshFromPull() }
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
                planNewTripCTA.padding(.top, Spacing.xs)
                Spacer()
                Spacer()
            }
            .padding(Spacing.xl)
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await refreshFromPull() }
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
                // Finding 3: a hanging join while offline has no timeout of
                // its own — this tells the user why, rather than leaving
                // them staring at a spinner that may never resolve.
                if appRouter.isJoiningTrip && syncStatus.isOffline {
                    Text("You\u{2019}re offline \u{2014} joining needs a connection. If this doesn\u{2019}t finish, open the invite link again when you\u{2019}re back online.")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xl)
                }
                Spacer()
                Spacer()
            }
            .padding(Spacing.xl)
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await refreshFromPull() }
    }

    /// First-launch-while-offline placeholder (finding 5) — distinct from
    /// `initialLoadState` because there's no pull in flight to wait on yet,
    /// and distinct from `emptyState` because a genuinely-empty account
    /// can't be told apart from "trips exist but haven't been pulled" until
    /// the first pull actually completes. Copy per §6.6: states what
    /// happened and how it resolves, no apology, and doesn't assert "first
    /// trip" the way `emptyState` does. `planNewTripCTA` stays present since
    /// offline trip creation still works via the outbox (§4.1 "always
    /// present").
    private var offlineFirstLoadState: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Spacer()
                Image(systemName: "wifi.slash")
                    .font(.system(size: 40))
                    .foregroundStyle(Palette.slate)
                VStack(spacing: Spacing.xs) {
                    Text("Can\u{2019}t check for trips yet")
                        .font(Typo.display(Typo.Size.title))
                        .foregroundStyle(Palette.ink)
                    Text("You\u{2019}re offline. Trips already on your account will appear once you\u{2019}re back online.")
                        .font(Typo.body())
                        .foregroundStyle(Palette.slate)
                        .multilineTextAlignment(.center)
                }
                planNewTripCTA.padding(.top, Spacing.xs)
                Spacer()
                Spacer()
            }
            .padding(Spacing.xl)
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await refreshFromPull() }
    }

    /// Failed-first/latest-pull placeholder (finding 1) — distinct from
    /// `emptyState` because a failed pull can't tell a genuinely-empty
    /// account apart from one whose trips just haven't been fetched yet;
    /// copy per §6.6 (states what happened and how it resolves, no
    /// apology), mirroring `offlineFirstLoadState`'s structure/tokens.
    /// `planNewTripCTA` stays present since offline/failed trip creation
    /// still works via the outbox (§4.1 "always present").
    private var pullFailedState: some View {
        ScrollView {
            VStack(spacing: Spacing.lg) {
                Spacer()
                Image(systemName: "exclamationmark.arrow.circlepath")
                    .font(.system(size: 40))
                    .foregroundStyle(Palette.slate)
                VStack(spacing: Spacing.xs) {
                    Text("Couldn\u{2019}t check for trips")
                        .font(Typo.display(Typo.Size.title))
                        .foregroundStyle(Palette.ink)
                    Text("The last check didn\u{2019}t reach the server. Trips on your account will appear once a check goes through.")
                        .font(Typo.body())
                        .foregroundStyle(Palette.slate)
                        .multilineTextAlignment(.center)
                }
                Button {
                    // Guards a double-tap from re-entering the pull while
                    // one's already in flight.
                    guard !isRetryingPull else { return }
                    Task {
                        retryFailedAgain = false
                        isRetryingPull = true
                        await syncEngine?.pullHome()
                        isRetryingPull = false
                        // Known accepted edge (same one `refreshFromPull()`
                        // documents above): a debounced pull already in
                        // flight makes `pullHome()` early-return, and this
                        // reads whatever `lastHomePullFailed` was left at by
                        // that earlier attempt rather than this tap's own
                        // outcome — rare, and the resulting note stays
                        // truthful either way.
                        retryFailedAgain = HomeRefreshFeedback.shouldNoteRetryFailure(
                            lastHomePullFailed: syncStatus.lastHomePullFailed,
                            isOffline: syncStatus.isOffline
                        )
                    }
                } label: {
                    HStack(spacing: Spacing.xs) {
                        if isRetryingPull {
                            ProgressView()
                                .tint(Palette.onAmber)
                        }
                        Text(isRetryingPull ? "Trying again\u{2026}" : "Try again")
                    }
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(Palette.onAmber)
                    .padding(.horizontal, Spacing.xl)
                    .padding(.vertical, Spacing.md)
                    .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor (finding 2)
                    .contentShape(Capsule())
                    .background(Palette.amber, in: Capsule())
                }
                .disabled(isRetryingPull)
                .padding(.top, Spacing.xs)
                if retryFailedAgain {
                    Text("Still couldn\u{2019}t reach the server. Check your connection and try again.")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, Spacing.xl)
                        .accessibilityAddTraits(.updatesFrequently)
                        .onAppear {
                            // Mirrors `ToastOverlay`'s announcement — a
                            // caption that appears on its own next to an
                            // already-read button needs an explicit nudge
                            // for VoiceOver to speak it.
                            AccessibilityNotification.Announcement(
                                "Still couldn\u{2019}t reach the server. Check your connection and try again."
                            ).post()
                        }
                }
                // Finding 4: recovery is the primary action in this one
                // placeholder, so the emphasis is swapped relative to the
                // other three states — `planNewTripCTA` (filled amber)
                // demotes to this outline style here, and "Try again" above
                // takes the filled treatment instead.
                planNewTripOutlineButton.padding(.top, Spacing.xs)
                Spacer()
                Spacer()
            }
            .padding(Spacing.xl)
            .containerRelativeFrame(.vertical)
        }
        .refreshable { await refreshFromPull() }
        .onChange(of: syncStatus.lastHomePullFailed) { _, failed in
            // A later re-entry into this placeholder (e.g. after a
            // background pull recovers, then fails again) shouldn't carry
            // over a stale note from a previous attempt.
            if !failed { retryFailedAgain = false }
        }
    }

    /// The style `Try again` had before finding 4's emphasis swap — reused
    /// here for `Plan a new trip` specifically in `pullFailedState`, where
    /// the filled treatment is reserved for the recovery action instead.
    private var planNewTripOutlineButton: some View {
        Button {
            isPresentingCreate = true
        } label: {
            Text("Plan a new trip")
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Spacing.xl)
                .padding(.vertical, Spacing.md)
                .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor (finding 2)
                .contentShape(Capsule())
                .background {
                    Capsule().strokeBorder(Palette.mist, lineWidth: 1.5)
                }
        }
    }

    /// Slim in-progress indicator for an invite claim (finding 6) — shown
    /// only once there's already a list to sit above; the empty-trips case
    /// is covered by `initialLoadState`.
    private var joiningTripBanner: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
            Text(syncStatus.isOffline ? "Joining trip\u{2026} \u{2014} waiting for a connection" : "Joining trip\u{2026}")
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
                .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor (finding 2)
                .contentShape(Capsule())
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
        // Finding 2: mirrors `TripView.canAddItems`' documented rule — a
        // signed-out session only ever contains locally created trips
        // (`AuthManager.signOut()` wipes the entire local mirror before
        // clearing the session, `SyncEngine.wipeForSignOut()`), so a
        // signed-out user is always the legitimately-permitted local
        // creator/organizer of every trip they can even see here.
        guard let userId = authManager.userId else { return true }
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

/// Conditionally attaches a trip card's edit/delete context menu (UX audit
/// finding 1). `.contextMenu { if isOrganizer { ... } }` always attaches the
/// modifier and just leaves the menu's *contents* empty for non-organizers —
/// that still gives a companion/viewer the long-press lift/haptic affordance
/// for a menu that opens to nothing. Gating the modifier itself (rather than
/// its contents) is the fix; the deprecated `contextMenu(ContextMenu?)`
/// overload is the only bool-gated variant of this API, so an `if`-based
/// `ViewModifier` is the supported shape instead.
private struct OrganizerTripMenu: ViewModifier {
    let isOrganizer: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void

    func body(content: Content) -> some View {
        if isOrganizer {
            content.contextMenu {
                Button("Edit trip", action: onEdit)
                Button("Delete trip", role: .destructive, action: onDelete)
            }
        } else {
            content
        }
    }
}
