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
    /// docs/UX_REDESIGN_ROADMAP.md Phase 5: backs every trip's own liveness
    /// (`HomeTripDayLabels.bucket`, via `TripDateBucketing.liveTimeZone`,
    /// computed once per render in `tripList`) and the "next"/"now"
    /// registers' FIRST-UP/today's-plan content, plus "been" row item
    /// counts. Filtered to `.confirmed` in `itemsByTripId` below,
    /// not here — an unreviewed email-import suggestion must never surface
    /// on Home (same EI-2 rule `TripView`'s own `@Query` already enforces)
    /// — but a plain in-Swift filter matches this file's existing
    /// convention (`people(for:)`/`isOrganizer(of:)` below already filter
    /// their own unfiltered queries in Swift) rather than adding a
    /// `#Predicate` + custom `init` just for this one query.
    @Query private var items: [ItineraryItem]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(SyncStatus.self) private var syncStatus
    @Environment(AppRouter.self) private var appRouter
    /// D2 defect 1: `header`'s AX-size restack, same `isAccessibilitySize`
    /// convention as `TripCard.swift`/`TripView.tabBar()`.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// PLAN-signature-layer.md §D1: gates the card -> hero flight (RM ->
    /// plain push, same convention as everywhere else this app checks it).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isPresentingCreate = false
    @State private var editingTrip: Trip?
    @State private var tripPendingDeletion: Trip?
    /// E2 (docs/BACKLOG.md §E2 "Duplicate trip"): the source trip while its
    /// "Duplicate Trip" create-mode sheet is up — distinct from `editingTrip`
    /// (that sheet opens `.edit` mode against the SAME trip; this one opens
    /// `.create` mode prefilled FROM this trip, producing an entirely new
    /// one — see `TripCardMenu`/`duplicateContent(from:into:)` below).
    @State private var tripToDuplicate: Trip?
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
    /// PLAN-signature-layer.md §D1: owns the card -> hero flight clone,
    /// injected via `.environment` on the `NavigationStack` below so
    /// `TripHeroView` can read/write it once pushed (see `HeroFlight.swift`'s
    /// doc comment).
    @State private var heroFlight = HeroFlightModel()
    /// Per-card frames, read at tap time to seed a flight's source rect.
    @State private var cardFrameIndex = CardFrameIndex()

    @ScaledMetric(relativeTo: .caption) private var valueRowIconSize: CGFloat = 13

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
                    } else {
                        // docs/UX_REDESIGN_ROADMAP.md Phase 5 (P5.1): one
                        // list now covers every trip (`orderedTrips` is
                        // `ahead + been`, exhaustive over `trips`), so the
                        // old "selected tab is empty but the other tab has
                        // content" branch this `else if` used to guard
                        // (`emptyTabState`) can no longer happen — deleted,
                        // not just unreached.
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
                // `-screenshotMode` hides this debug menu so App Store captures
                // are clean — it's still a Debug build, so DemoSeeder and the
                // `-uitest*` hooks keep working while the ladybug stays hidden.
                if !ProcessInfo.processInfo.arguments.contains("-screenshotMode") {
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
                }
                #endif
            }
            .sheet(isPresented: $isPresentingCreate) {
                // docs/UX_REDESIGN_ROADMAP.md Phase 5: one list now covers
                // every trip, so a saved trip is always visible somewhere in
                // it — finding 2's old tab-routing concern (`selectedTab =
                // trip.bucket().isPastTab ? "Past" : "Upcoming"`) no longer
                // has anything to route between.
                TripFormView(mode: .create) { _, _ in
                    // Create-mode always reports `.saved` — it hard-stops on
                    // a nil `userId` before ever reaching a save.
                    toast = "Trip created"
                }
            }
            .sheet(item: $editingTrip) { trip in
                TripFormView(mode: .edit(trip)) { _, outcome in
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
                } onDeleted: {
                    // UX audit finding 8: this edit sheet now offers "Delete
                    // trip" too (previously only reachable via swipe/context
                    // menu) — same confirmation feedback as those.
                    toast = "Trip deleted"
                }
            }
            // E2 (docs/BACKLOG.md §E2): reuses the exact same create sheet —
            // `mode` is genuinely `.create`, just seeded away from the usual
            // blank defaults (`TripDuplication.prefill`). Landing back on
            // this list with a toast (not auto-navigating into the new trip)
            // matches the existing "Plan a new trip" convention above rather
            // than inventing a second one.
            .sheet(item: $tripToDuplicate) { sourceTrip in
                TripFormView(mode: .create, prefill: TripDuplication.prefill(for: sourceTrip)) { newTrip, _ in
                    // P5 fix-round: don't say "duplicated" if the clone
                    // save actually failed — the trip itself still exists
                    // (created via the sheet's own hardened save above),
                    // just without its copied plans. D1: `duplicateContent`
                    // is now async (it pulls the source trip's items first —
                    // see `HomeDuplication`), so it runs in a `Task`; the
                    // sheet has already dismissed, the toast lands on Home.
                    Task {
                        toast = await duplicateContent(from: sourceTrip, into: newTrip)
                            ? "Trip duplicated"
                            : "Trip created, but copying its plans didn\u{2019}t finish \u{2014} pull to refresh and try again."
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
                    // Finding 2 (partial): closes the feedback loop on a
                    // hard local delete — the row just vanished from the
                    // list with no confirmation it actually happened.
                    toast = "Trip deleted"
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
        // PLAN-signature-layer.md §D1: injects the flight model down into
        // whatever gets pushed (`TripHeroView` reads it via `@Environment`),
        // then draws the flight clone above the pushed content itself --
        // both attached to the `NavigationStack`, not the outer `ZStack`
        // sibling above it, so the overlay tracks whichever screen is
        // currently on top of the stack.
        .environment(heroFlight)
        .overlay { HeroFlightOverlay(model: heroFlight) }
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

    /// Shared path for all five `.refreshable { }` closures on Home (finding
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

    /// D2 defect 1: at accessibility Dynamic Type sizes the fixed-width
    /// settings avatar (44pt) starved `greetingBlock` of width inside the
    /// default `HStack` below, and "Your trips" (`Typo.display()`, this
    /// screen's biggest font) mid-word-truncated to "Your tri…" instead of
    /// wrapping — essential heading text must never do that. Same
    /// `isAccessibilitySize` restructure as `TripCard`/`TripView.tabBar()`/
    /// `PersonFilterBar`: the avatar moves to its own trailing-aligned row
    /// above the greeting/title block instead of squeezing it horizontally,
    /// so the heading always gets the sheet's full width to wrap into (at
    /// word boundaries, per `Text`'s own default — no `.lineLimit` added).
    /// Default rendering (the `else` branch) is untouched.
    private var header: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    HStack {
                        Spacer()
                        settingsAvatar
                    }
                    greetingBlock
                }
            } else {
                HStack(alignment: .top) {
                    greetingBlock
                    Spacer()
                    settingsAvatar
                }
            }
        }
    }

    private var greetingBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if isProfileStillLoading {
                // Finding 4: no profile has hydrated yet — a redacted
                // placeholder keeps the layout height stable without
                // asserting a fake "Traveler" identity that reads as
                // wrong once the real name lands.
                Text("Good morning, Traveler")
                    .font(Typo.body(weight: .medium))
                    .foregroundStyle(Palette.slate)
                    .redacted(reason: .placeholder)
            } else {
                // P5 fix-round (ux-expert fix-now): `greeting` already
                // degrades to plain "Good evening" (no trailing name/comma)
                // once `myDisplayName` is nil — this branch is what makes
                // that render as a genuinely SETTLED state, not a
                // still-loading one (see `isProfileStillLoading`'s doc
                // comment).
                Text(greeting)
                    .font(Typo.body(weight: .medium))
                    .foregroundStyle(Palette.slate)
            }
            Text("Your trips")
                .font(Typo.display())
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
        }
    }

    // NavigationLink(value:), same reasoning as TripView's share button:
    // pushes SettingsRoute onto this stack (M3 brief: "Reachable from
    // HomeView (avatar tap → Settings)").
    private var settingsAvatar: some View {
        NavigationLink(value: SettingsRoute()) {
            Circle()
                .fill(Palette.indigo)
                .frame(width: 42, height: 42)
                .overlay {
                    if let myDisplayName {
                        Text(initials(from: myDisplayName))
                            .font(Typo.display(16))
                            .foregroundStyle(.white)
                    } else {
                        // Finding 4: no bogus "T" initial before the
                        // profile hydrates.
                        Image(systemName: "person.fill")
                            .foregroundStyle(.white)
                    }
                }
                // 44pt hit target (§6.5) around the 42pt visual circle —
                // finding 8.
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("Settings")
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: .now)
        let period: String
        switch hour {
        case 0..<12: period = "morning"
        case 12..<17: period = "afternoon"
        default: period = "evening"
        }
        guard let myDisplayName else { return "Good \(period)" }
        return "Good \(period), \(firstName(from: myDisplayName))"
    }

    private var myProfile: Profile? {
        guard let userId = authManager.userId else { return nil }
        return profiles.first { $0.id == userId }
    }

    /// Finding 4: `nil` until the signed-in user's own profile row has
    /// hydrated locally — driving both the greeting and the avatar so
    /// neither renders a fake "Traveler" identity in the meantime.
    private var myDisplayName: String? {
        myProfile?.displayName
    }

    /// P5 fix-round (ux-expert fix-now): finding 4's own `myDisplayName ==
    /// nil` check conflated "still loading" with "settled, and there's
    /// genuinely no profile for me" — a SIGNED-OUT session (`myProfile`'s
    /// own doc comment: no `userId` at all to look one up by) or a
    /// signed-in session whose first pull already completed with no
    /// matching row are both SETTLED facts, not "still loading," yet the
    /// old check showed the redacted skeleton FOREVER for either — reading
    /// as permanently broken. Reuses `SyncStatus.hasCompletedInitialHomePull`,
    /// the exact same loading/settled signal `HomeEmptyPlaceholder.resolve`
    /// already uses for the trips list itself, so the two can't disagree
    /// about whether this session has "settled" yet.
    private var isProfileStillLoading: Bool {
        myDisplayName == nil && authManager.userId != nil && !syncStatus.hasCompletedInitialHomePull
    }

    // MARK: - List

    /// Card tap -> trip screen (PLAN-signature-layer.md §D1). Flies the
    /// tapped card's clone to the hero when motion/text-size allow and a
    /// source frame was actually measured (`HeroFlightGate`); otherwise
    /// falls back to exactly today's plain push. Deep-link/autopilot pushes
    /// (`appRouter.tripToOpen`'s `.onChange`, `applyUITestAutopilotIfNeeded`)
    /// call `path.append` directly and never go through here, so they stay
    /// plain pushes unconditionally -- they don't originate from a visible
    /// card to fly from. `register` defaults to `.plain` — "been" rows (the
    /// only other caller) never fly anyway (no `.cardFrameTracking`, so
    /// `hasSourceFrame` is always false there), so the value is inert for
    /// them; ahead rows pass the SAME register value their own `TripCard`
    /// renders (P5 fix-round item 12), so the flight clone matches it.
    private func openTrip(_ trip: Trip, register: HomeCardRegister = .plain) {
        // Ignore taps while a flight is already in flight.
        guard heroFlight.state == .idle else { return }
        let sourceFrame = cardFrameIndex.frames[trip.id]
        guard HeroFlightGate.shouldFly(
            reduceMotion: reduceMotion, isAccessibilitySize: dynamicTypeSize.isAccessibilitySize,
            hasSourceFrame: sourceFrame != nil
        ), let sourceFrame else {
            path.append(TripRoute(id: trip.id))
            return
        }
        heroFlight.destFrame = nil
        heroFlight.state = .flying(
            trip: trip, people: people(for: trip),
            isPending: syncStatus.pendingRowIds.contains(trip.id), register: register, sourceFrame: sourceFrame
        )
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            path.append(TripRoute(id: trip.id))
        }
    }

    /// docs/UX_REDESIGN_ROADMAP.md Phase 5 (P5.1–P5.5): one list, three
    /// registers. `List` (not the `ScrollView`+`LazyVStack(pinnedViews:)`
    /// recipe `ItineraryTabView` uses for its own pinned day headers) stays
    /// the container here — deliberately: `List`'s native `Section` headers
    /// already pin on `.plain` style (the exact behavior "sticky year
    /// headers" needs), and keeping `List` means the "been" rows inherit
    /// `.swipeActions` for free, both its drag mechanics *and* VoiceOver's
    /// automatic custom-actions rotor exposure — a hand-rolled swipe gesture
    /// would need to reimplement that accessibility path by hand to avoid a
    /// regression against the "registers are one list to a screen reader"
    /// contract. Flagged for review in the handoff, since the roadmap's own
    /// phrasing points at `LazyVStack`.
    ///
    /// Reviewer perf finding: `itemsByTripId`/the per-trip bucket/`ahead`/
    /// `been` used to be computed FRESH on every access — `registerKind(for:)`
    /// alone re-ran `aheadTrips` (itself a full trips × items pass) once per
    /// ROW. All four are now computed exactly once per render pass here and
    /// threaded through as locals/params — same "compute once at the top of
    /// body, thread as locals" recipe `ItineraryTabView.body` already uses
    /// for its own `models`/`hintDayId`/`todayTargetId`.
    private var tripList: some View {
        let itemsByTripId = itemsByTripId
        let bucketsByTripId = Dictionary(uniqueKeysWithValues: trips.map { trip in
            (trip.id, HomeTripDayLabels.bucket(trip: trip, liveTimeZone: TripDateBucketing.liveTimeZone(items: itemsByTripId[trip.id] ?? [])))
        })
        let bucketLookup: (Trip) -> TripBucket = { bucketsByTripId[$0.id] ?? .upcoming }
        let aheadTrips = HomeTripOrdering.ahead(trips, bucket: bucketLookup)
        let beenTrips = HomeTripOrdering.been(trips, bucket: bucketLookup)
        let aheadFirstId = aheadTrips.first?.id
        let beenYears = beenYears(in: beenTrips)

        return List {
            ForEach(aheadTrips) { trip in
                // Computed once per row and handed to BOTH `TripCard` and
                // `openTrip` (P5 fix-round item 12) — the flight clone
                // renders the exact same register the tapped card did.
                let register = cardRegister(
                    for: trip, aheadFirstId: aheadFirstId, bucket: bucketsByTripId[trip.id] ?? .upcoming,
                    itemsByTripId: itemsByTripId
                )
                Button {
                    openTrip(trip, register: register)
                } label: {
                    TripCard(
                        trip: trip,
                        people: people(for: trip),
                        isPending: syncStatus.pendingRowIds.contains(trip.id),
                        register: register
                    )
                    .padding(.horizontal, Spacing.xl)
                    // PLAN-signature-layer.md §D1: measures this exact
                    // (padded) card rect -- what `openTrip` reads as the
                    // flight's source frame.
                    .cardFrameTracking(id: trip.id, index: cardFrameIndex)
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
                .modifier(TripCardMenu(
                    isOrganizer: isOrganizer(of: trip),
                    onEdit: { editingTrip = trip },
                    onDelete: { tripPendingDeletion = trip },
                    onDuplicate: { tripToDuplicate = trip }
                ))
            }

            if !beenTrips.isEmpty {
                beenSectionHeader(count: beenTrips.count)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)

                ForEach(beenYears, id: \.self) { year in
                    Section {
                        ForEach(beenTrips.filter { Calendar.current.component(.year, from: $0.endDate) == year }) { trip in
                            beenRow(trip, itemCount: itemsByTripId[trip.id]?.count ?? 0)
                        }
                    } header: {
                        yearHeader(year)
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
        // the fallback. P5.5: also the "launch always opens at top" check —
        // `List` never restores/persists a scroll position across a fresh
        // `HomeView` instantiation on its own, and nothing here adds any
        // (no `@SceneStorage`/`ScrollViewReader` offset-restoring code),
        // so a cold launch always starts at the top for free.
        .refreshable { await refreshFromPull() }
    }

    /// P5.2/P5.3: resolves the "next"/"now" registers' extra content once
    /// per card — `.plain` (unchanged rendering) for every other ahead trip.
    /// Takes the already-computed `aheadFirstId`/`bucket`/`itemsByTripId`
    /// (see `tripList`'s own doc comment) rather than re-deriving any of
    /// them itself.
    private func cardRegister(
        for trip: Trip, aheadFirstId: UUID?, bucket: TripBucket, itemsByTripId: [UUID: [ItineraryItem]]
    ) -> HomeCardRegister {
        switch HomeRegister.kind(for: trip, aheadFirstId: aheadFirstId, bucket: bucket) {
        case .next:
            let firstUp = HomeFirstUp.pick(from: itemsByTripId[trip.id] ?? [])
            return .next(firstUp: firstUp.map(HomeFirstUp.init))
        case .now:
            let tz = TripDateBucketing.liveTimeZone(items: itemsByTripId[trip.id] ?? [])
            let todayRows = HomeTodayPlan.items(
                in: itemsByTripId[trip.id] ?? [], tripStart: HomeTripDayLabels.tripStart(trip), liveTimeZone: tz
            )
            let panel = HomeTodayPanel.make(trip: trip, todayRows: todayRows, liveTimeZone: tz)
            return .now(panel: panel)
        case .plain, .been:
            return .plain
        }
    }

    /// P5.4: "Been there" — a plain (non-sticky) row that introduces the
    /// archive once, above the first sticky year header. Matches the
    /// mockup's `.arch` (title + hairline rule + trip-count eyebrow); no
    /// search entry (not in this phase's scope).
    ///
    /// Reviewer nit: the title was sized/weighted to the mockup's own CSS
    /// numbers (19px/600) but still read as competing with `header`'s "Your
    /// trips" H1 in context — quieted a step further (17pt, `Spacing.xl`
    /// top padding instead of `.xxl`) toward the mockup's own hairline-rule
    /// register, and gains `.isHeader` (it names a real navigational
    /// division of the list, same as the year headers below it do).
    private func beenSectionHeader(count: Int) -> some View {
        HStack(spacing: Spacing.md) {
            Text("Been there")
                .font(Typo.display(17))
                .foregroundStyle(Palette.ink)
            Rectangle().fill(Palette.mist).frame(height: 1)
            Text("\(count) trip\(count == 1 ? "" : "s")")
                .font(Typo.body(10.5, weight: .bold))
                .tracking(0.8)
                .textCase(.uppercase)
                .foregroundStyle(Palette.slate)
                .fixedSize()
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.xl)
        .padding(.bottom, Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// Sticky year header (P5.4) — same `Palette.paper`-fade recipe as
    /// `ItineraryTabView.dayHeaderBackground`, so content scrolling
    /// underneath a pinned header fades rather than hard-clipping.
    private func yearHeader(_ year: Int) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(String(year))
                .font(Typo.body(11, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Palette.slate)
            Rectangle().fill(Palette.mist).frame(height: 1)
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.sm)
        .background(yearHeaderBackground)
        .listRowInsets(EdgeInsets())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(String(year))
        .accessibilityAddTraits(.isHeader)
    }

    private var yearHeaderBackground: some View {
        VStack(spacing: 0) {
            Palette.paper
            LinearGradient(colors: [Palette.paper, Palette.paper.opacity(0)], startPoint: .top, endPoint: .bottom)
                .frame(height: 8)
        }
    }

    /// P5.4: a "been" trip's muted compact row. Tapping reuses `openTrip`
    /// unchanged — `cardFrameTracking` is never attached to a `BeenRow`
    /// (it isn't `TripCard`-shaped), so `HeroFlightGate` sees no source
    /// frame for it and `openTrip` already falls back to a plain push, with
    /// no separate "been rows never fly" branch needed.
    private func beenRow(_ trip: Trip, itemCount: Int) -> some View {
        Button {
            openTrip(trip)
        } label: {
            BeenRow(trip: trip, itemCount: itemCount)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
        .listRowSeparatorTint(Palette.mist)
        // P5.4: trailing only (matches the mockup's own reveal direction).
        // Reviewer nit: this used to ALSO register on `.leading` — the same
        // action on both edges meant VoiceOver's custom-actions rotor listed
        // "Copy to a new trip" twice for one row, with no way to tell the
        // two apart. `.swipeActions` buttons are auto-exposed to that rotor
        // (the whole reason `List` stayed the container for "been" rows —
        // see `tripList`'s own doc comment), so the fix is to stop
        // registering the duplicate at the source rather than fight that
        // auto-exposure. The context menu below still reaches the same
        // action a second way, deliberately (kept per the brief).
        .swipeActions(edge: .trailing) { copyToNewTripSwipeAction(trip) }
        .contextMenu {
            Button {
                tripToDuplicate = trip
            } label: {
                Label("Copy to a new trip", systemImage: "plus.square.on.square")
            }
        }
    }

    private func copyToNewTripSwipeAction(_ trip: Trip) -> some View {
        Button {
            tripToDuplicate = trip
        } label: {
            Label("Copy to a new trip", systemImage: "plus.square.on.square")
        }
        // Not `.tint(Palette.amber)`: a `.swipeActions` button's label is
        // system-rendered in fixed white regardless of any `Label`/`Text`
        // styling here, and white-on-amber measures ~2.4:1 (`PaletteExtras
        // .swift`'s `onAmber` doc comment — fails AA outright). `.indigo` is
        // `PackingListView`'s own precedent for exactly this shape (a
        // non-destructive swipe action needing a tint) — white-on-indigo
        // measures ~12.8:1.
        .tint(Palette.indigo)
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
                // W1-D: EmptyStateArt replaces the old bare glyph here —
                // decorative, fixed size, accessibilityHidden internally;
                // the headline right below already carries the message.
                EmptyStateArt(scene: .home)
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
                .font(.system(size: valueRowIconSize, weight: .semibold))
                .foregroundStyle(Palette.amber)
                .frame(width: 20)
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
        }
        // One VoiceOver stop per bullet (icon + text), not two.
        .accessibilityElement(children: .combine)
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
                    // Decorative empty-state glyph — same deliberate cap as
                    // `emptyState`'s icon above.
                    .font(.system(size: 40))
                    .foregroundStyle(Palette.slate)
                    .accessibilityHidden(true)
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
                    // Decorative empty-state glyph — same deliberate cap as
                    // `emptyState`'s icon above.
                    .font(.system(size: 40))
                    .foregroundStyle(Palette.slate)
                    .accessibilityHidden(true)
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

    // MARK: - Derived data (docs/UX_REDESIGN_ROADMAP.md Phase 5)

    /// This trip's own confirmed items — backs the per-trip live-timezone
    /// bucket and the "next"/"now"/"been" registers' content. Read exactly
    /// once per render pass, at the top of `tripList` (reviewer perf
    /// finding — see that property's own doc comment); every other
    /// `@Query`-derived collection here (`trips`, `tripProfiles`,
    /// `tripMembers`) is small enough per access that only this one needed
    /// hoisting.
    private var itemsByTripId: [UUID: [ItineraryItem]] {
        Dictionary(grouping: items.filter { $0.status == .confirmed }, by: \.tripId)
    }

    /// P5.4: distinct years among `beenTrips`, in the same most-recent-first
    /// order (grouped by `endDate`'s year — the same field `been`'s own
    /// sort already keys off, so a trip that crosses a year boundary can't
    /// land in a section that disagrees with its own sort position). Takes
    /// the already-ordered `beenTrips` rather than re-deriving it.
    private func beenYears(in beenTrips: [Trip]) -> [Int] {
        var seen = Set<Int>()
        var years: [Int] = []
        for trip in beenTrips {
            let year = Calendar.current.component(.year, from: trip.endDate)
            if seen.insert(year).inserted { years.append(year) }
        }
        return years
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

    /// E2 (docs/BACKLOG.md §E2): runs right after `tripToDuplicate`'s create
    /// sheet saves the new trip row — clones `sourceTrip`'s confirmed items
    /// and packing list into it. The gather-and-clone lives in the testable
    /// `HomeDuplication.cloneContent`; this method only supplies the context/
    /// user, the source-pull closure, and the outbox enqueue.
    ///
    /// The outbox enqueue loop is async and awaited sequentially inside one
    /// `Task` — off the toast/return path, and ordered the same FIFO way the
    /// outbox's own push already expects.
    /// ponytail: a genuinely enormous trip could still make the synchronous
    /// insert loop (inside `cloneContent`) hitch; `DemoSeeder`'s ~70-item
    /// fixture is the existing ceiling this app already accepts for this shape
    /// of write. Move that loop to a background `ModelActor` (like `SyncStore`)
    /// if it ever proves real.
    ///
    /// D1 (qa): FIRST UP was intermittently missing after a swipe-copy because
    /// `pullHome` never loads itinerary items/packing (only `pullTrip`, on
    /// trip-open, does — `SyncEngine+Pull`) — so duplicating a past trip never
    /// opened this session read an EMPTY local set and the empty-source guard
    /// reported success, producing an itemless copy that survived a cold
    /// relaunch. Root-caused and covered by `HomeDuplicationTests`; the fix is
    /// the `pullTrip` in `ensureSourceLoaded` below (earlier repro attempts
    /// came back green only because they used trips whose items were already
    /// in the mirror). Offline duplication of a still-unopened trip stays a
    /// known gap: `pullTrip` no-ops offline, so there's nothing local to clone
    /// — see docs/BACKLOG.md.
    /// - Returns: `false` only if the items/packing save itself threw —
    ///   `true` covers both "cloned successfully" and "nothing to clone"
    ///   (the source trip was simply empty, not a failure).
    @discardableResult
    private func duplicateContent(from sourceTrip: Trip, into newTrip: Trip) async -> Bool {
        guard let userId = authManager.userId else { return false }
        let sourceTripId = sourceTrip.id
        // Capture value copies before the `await` below so no `@Model` is held
        // across the suspension (`pullTrip` hops to the `SyncEngine` actor).
        let sourceStart = sourceTrip.startDate
        let newTripId = newTrip.id
        let newStart = newTrip.startDate

        guard let cloned = await HomeDuplication.cloneContent(
            sourceTripId: sourceTripId, sourceStart: sourceStart,
            newTripId: newTripId, newStart: newStart, createdBy: userId, modelContext: modelContext,
            // D1 (qa): items/packing enter the mirror only via `pullTrip`, so
            // pull the source's rows before cloning — otherwise a trip never
            // opened this session clones an empty set (see `HomeDuplication`).
            ensureSourceLoaded: { await syncEngine?.pullTrip(sourceTripId) }
        ) else {
            return false
        }

        let clonedItems = cloned.items
        let clonedPacking = cloned.packing
        Task {
            for item in clonedItems {
                await syncEngine?.enqueueUpsert(table: .itineraryItems, rowId: item.id, tripId: newTripId, payload: item.toDTO())
            }
            for packingItem in clonedPacking {
                await syncEngine?.enqueueUpsert(table: .packingItems, rowId: packingItem.id, tripId: newTripId, payload: packingItem.toDTO())
            }
        }
        return true
    }
}

/// Trip card's long-press context menu (UX audit finding 1 for Edit/Delete;
/// E2, docs/BACKLOG.md §E2, adds Duplicate). Edit/Delete stay organizer-gated
/// — they mutate the shared trip. Duplicate is ungated: it only reads a trip
/// every member already has view access to (BUILD_PLAN §5.1 — even a viewer
/// "can view, not edit"; reading is never the restricted part) and creates a
/// brand-new trip the duplicator alone owns, the same "read access is
/// enough" call `TripHeroView`'s E1 overflow menu already made for "Add Trip
/// to Calendar." Duplicate being unconditionally present also means this
/// modifier can attach `.contextMenu` unconditionally now — the old
/// empty-menu-for-non-organizers problem the previous `if isOrganizer { ... }
/// else { content }` guarded against (a long-press lift/haptic that opened
/// to nothing) can't recur, since there's always at least one real action.
private struct TripCardMenu: ViewModifier {
    let isOrganizer: Bool
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onDuplicate: () -> Void

    func body(content: Content) -> some View {
        content.contextMenu {
            if isOrganizer {
                Button("Edit trip", action: onEdit)
            }
            Button {
                onDuplicate()
            } label: {
                Label("Duplicate Trip", systemImage: "plus.square.on.square")
            }
            if isOrganizer {
                Button("Delete trip", role: .destructive, action: onDelete)
            }
        }
    }
}
