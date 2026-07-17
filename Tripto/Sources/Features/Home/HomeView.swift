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
    /// UX P6.5: "Show past trips" — device-local, deliberately not synced
    /// (`SettingsView`'s own `@AppStorage` on the same key is the toggle;
    /// this is the read side that collapses the "been" register). Defaults
    /// `true` so a fresh install/existing user sees today's unchanged
    /// behavior until they explicitly opt to hide.
    @AppStorage(HomePastTripsVisibility.appStorageKey) private var showPastTrips = true

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
    /// P6.2 (docs/UX_REDESIGN_ROADMAP.md): the duplicate-trip merge's 6s
    /// "stack settles" grace period — see `startMerge(shell:survivor:)`'s
    /// own doc comment for why this replaces a literal post-hoc undo.
    /// `nil` whenever no merge is pending; only one merge can be pending at
    /// a time (guarded in `startMerge`), matching this app's usual single-
    /// in-flight-op convention (`isRetryingPull`, `busyShareLink`).
    @State private var mergeCountdown: MergeCountdown?
    /// D3(b) fix round: the merge strip's tap opens this confirmation
    /// BEFORE `startMerge`'s countdown starts — a plain tuple (not a new
    /// named struct) since it's transient UI state read only by the one
    /// `.confirmationDialog` below.
    @State private var mergePendingConfirm: (shell: Trip, survivor: Trip)?

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
            .overlay(alignment: .bottom) { mergeCountdownOverlay }
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
            // D3(b) (docs/UX_REDESIGN_ROADMAP.md P6.2 fix round): the
            // duplicate-trip merge's explicit confirm gate, BEFORE the 6s
            // countdown even starts — same shape as the "Delete trip"
            // dialog right above.
            .confirmationDialog(
                "Merge trips?",
                isPresented: Binding(
                    get: { mergePendingConfirm != nil },
                    set: { isPresented in if !isPresented { mergePendingConfirm = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Merge", role: .destructive) {
                    if let pending = mergePendingConfirm { startMerge(shell: pending.shell, survivor: pending.survivor) }
                    mergePendingConfirm = nil
                }
                // P7 award-audit (MED, VoiceOver escape) — reviewer follow-up:
                // empirically confirmed (accessibility-tree dump, both an
                // iPhone-compact and iPad-regular sim) this dialog renders as
                // a genuine `Popover` element in this OS build on BOTH size
                // classes, not just regular — a `PopoverDismissRegion` sibling
                // and exactly one action button ("Merge") is everything in
                // the tree; NEITHER a plain-role NOR a `.cancel`-role second
                // button ever renders, on either width. So role choice here
                // doesn't change what's on screen either way — kept
                // `role: .cancel` (semantically correct, and consistent with
                // the "Delete trip" dialog above) rather than the plain
                // button an earlier pass here swapped in on a theory this
                // data doesn't support. The dismiss that DOES work
                // everywhere: tapping outside (`PopoverDismissRegion`, always
                // present) and VoiceOver's system-standard scrub/escape
                // gesture on the presented popover — both platform-provided,
                // not app-wired — and this dialog's own `isPresented`
                // binding `set` above already resets `mergePendingConfirm`
                // on exactly that path, button-independent.
                Button("Cancel", role: .cancel) { mergePendingConfirm = nil }
            } message: {
                if let pending = mergePendingConfirm {
                    Text(
                        "Moves everything into \u{201C}\(pending.survivor.title)\u{201D} and deletes this trip. "
                            + "You\u{2019}ll have a few seconds to undo \u{2014} after that, it can\u{2019}t be reversed."
                    )
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
        // P7b suite-health fix (p7-shots/MANIFEST.md "Suite health"): a
        // full-class `TriptoUITests` run shares one persistent app install/
        // store across test methods, which broke order-independence TWO
        // ways once a differently-flagged test ran first:
        //  1. A showcase flag names an EXACT fixture (`DemoSeeder.seed`'s
        //     own `-uitestSeedRegisterShowcase`/`-uitestSeedNextRegisterShowcase`/
        //     `-uitestSeedP6TrustShowcase` checks), but `seed()` early-
        //     returns the moment a trip named "Lisbon" already exists,
        //     skipping every showcase call below that guard (`DemoSeeder
        //     .swift`'s own doc comment) — so a showcase-flagged launch
        //     after ANY earlier seed silently never got its own content.
        //  2. Even a plain `-uitestSeedIfEmpty` launch (no showcase flag)
        //     used to skip calling `seed()` at all once `trips.isEmpty` was
        //     false, falling back to `trips.first?.id` — correct only when
        //     "Lisbon" happens to sort first; the moment an earlier,
        //     differently-flagged test left a trip that sorts before it by
        //     `startDate`, this opened the WRONG trip (confirmed live:
        //     `testSeededTripOpensAndTabsRender`, which carries no showcase
        //     flag at all, failed the exact same "seeded trip hero title
        //     never appeared" way after a showcase test ran first).
        // Fix: reset the store first when a showcase flag needs fresh sub-
        // seeding a stale "Lisbon" would otherwise block, THEN always call
        // `seed()` (not just when `trips.isEmpty`) — cheap even when
        // "Lisbon" already exists (one fetch, immediate return of its id;
        // see `DemoSeeder.seed`'s own idempotence guard), so `targetTripId`
        // always resolves to the actual "Lisbon" trip regardless of what
        // else is in the store or how it sorts. Every launch in this suite
        // passes `-simulateOffline`, so `resetLocalStore()`'s own re-pull
        // never fires (its early-return right after the wipe) — this stays
        // exactly as hermetic/no-network as the rest of the suite.
        let showcaseFlags = [
            "-uitestSeedRegisterShowcase", "-uitestSeedNextRegisterShowcase", "-uitestSeedP6TrustShowcase",
            "-uitestSeedAvatarShowcase", "-uitestSeedCoverShowcase"
        ]
        let needsShowcaseReset = !trips.isEmpty && showcaseFlags.contains { arguments.contains($0) }
        if arguments.contains("-uitestSeedIfEmpty") {
            if needsShowcaseReset {
                await syncEngine?.resetLocalStore()
            }
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
    ///
    /// P7b craft-audit fix: that P5 fix-round still missed a THIRD settled
    /// case — offline with no cached profile. `pullHome()` no-ops while
    /// offline, so `hasCompletedInitialHomePull` can never flip true there
    /// either, and the skeleton stayed up forever on exactly that
    /// combination (every `home-*` P7 screenshot). Delegates to
    /// `HomeGreetingLoading.isStillLoading` (`HomeRegisters.swift`), which
    /// now also settles on `isOffline` — see that function's own doc comment.
    private var isProfileStillLoading: Bool {
        HomeGreetingLoading.isStillLoading(
            hasDisplayName: myDisplayName != nil, isSignedIn: authManager.userId != nil,
            hasCompletedInitialHomePull: syncStatus.hasCompletedInitialHomePull, isOffline: syncStatus.isOffline
        )
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
        // P6.2: adjacent-pair duplicate detection over `aheadTrips` only —
        // the mockup's own two example cards are both upcoming, and a
        // "been" trip is already archival (nothing to actively merge into
        // day-to-day). Computed once here, same "once per render pass"
        // convention as every other lookup above.
        let duplicateSurvivorByShellId = TripMergeDetection.survivorByShellId(in: aheadTrips)
        // UX P6.6: hoisted so `planNewTripRow`'s own trailing-margin check
        // (now sitting directly above the "been" content, see that row's own
        // comment below) and the `if` below it agree on the exact same
        // value, rather than calling this twice.
        let showHiddenRow = HomePastTripsVisibility.shouldShowHiddenRow(showPastTrips: showPastTrips, beenCount: beenTrips.count)

        return List {
            ForEach(aheadTrips) { trip in
                // Computed once per row and handed to BOTH `TripCard` and
                // `openTrip` (P5 fix-round item 12) — the flight clone
                // renders the exact same register the tapped card did.
                let register = cardRegister(
                    for: trip, aheadFirstId: aheadFirstId, bucket: bucketsByTripId[trip.id] ?? .upcoming,
                    itemsByTripId: itemsByTripId
                )
                // P6.2: only offered when the signed-in user can edit BOTH
                // trips (`isOrganizer(of:)` — already this app's "createdBy
                // or organizer" check, see that method's own doc comment) —
                // a merge neither role could complete would be a dead end.
                let duplicateSurvivor = duplicateSurvivorByShellId[trip.id].flatMap {
                    canMergeTrips(trip, $0) ? $0 : nil
                }

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
                // P6.2: tightened (not zero — a hairline still separates
                // the two) when a duplicate strip follows immediately
                // below, approximating the mockup's fused pair without
                // touching `TripCard`'s own corner radii (see
                // `DuplicateTripStrip`'s doc comment).
                .padding(.bottom, duplicateSurvivor != nil ? Spacing.xxs : Spacing.lg)
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

                if let survivor = duplicateSurvivor {
                    // D6 (reviewer, MED — silent dead button): disabled +
                    // visually dimmed, not just functionally blocked, while
                    // ANY merge (this pair's own, or a different one) is
                    // already pending — a tap that can't do anything must
                    // never look tappable. Covers a re-tap of this SAME
                    // strip mid-countdown too, not just a second, different
                    // pair (`DuplicateTripStrip`'s own doc comment).
                    DuplicateTripStrip(survivorTitle: survivor.title, isMergePending: mergeCountdown != nil) {
                        // D3(b) (security+reviewer, MED — auto-fires with no
                        // confirmation): "Merge" opens a confirmation dialog
                        // first; the countdown itself only starts once the
                        // user confirms (`mergeConfirmationDialog` below).
                        mergePendingConfirm = (shell: trip, survivor: survivor)
                    }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.lg)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
            }

            // UX P6.6 (create-action reachability — ux-expert P5 fix-round
            // finding + client direction): moved here, directly above the
            // "been" content, from the true list end (P5.5's original spot)
            // — a growing archive used to bury this affordance at the
            // bottom of an ever-longer scroll. VoiceOver reads it in this
            // same order: the create action before the archive header.
            // `showHiddenRow || !beenTrips.isEmpty` mirrors the `if`/`else
            // if` immediately below — zero past trips means NEITHER branch
            // renders, so this stays the exact last row with no added
            // trailing margin, same as before this move.
            planNewTripRow
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .padding(.bottom, showHiddenRow || !beenTrips.isEmpty ? Spacing.lg : 0)

            // UX P6.5: "Show past trips" off collapses the whole archive
            // into one quiet reveal row instead — `shouldShowHiddenRow`
            // already accounts for the empty-archive case (false there
            // regardless of the setting), so the `else if !beenTrips
            // .isEmpty` below stays the exact pre-P6.5 expanded rendering.
            if showHiddenRow {
                hiddenPastTripsRow(count: beenTrips.count)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            } else if !beenTrips.isEmpty {
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

    /// UX P6.5: the collapsed "been" register's own row — tapping "Show"
    /// flips the setting back on (never a toggle here, always on: this row
    /// only ever renders while it's off) rather than reopening Settings.
    private func hiddenPastTripsRow(count: Int) -> some View {
        HiddenPastTripsRow(count: count) { showPastTrips = true }
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
                EmptyState(
                    scene: .home,
                    title: "Plan your first trip",
                    horizontalPadding: 0,
                    titleAlignment: .leading,
                    subtitle: "Everyone\u{2019}s bookings in one shared, at-a-glance itinerary."
                ) {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        valueRow("clock", "Every flight and plan in its own local time")
                        valueRow("person.2", "Invite family \u{2014} or share a link, no app needed")
                        valueRow("suitcase", "A shared packing list, and \u{201C}just mine\u{201D} per person")
                    }
                    .padding(.top, Spacing.xs)
                    planNewTripCTA
                        .padding(.top, Spacing.xs)
                }
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
                }
                .buttonStyle(.primaryCapsule)
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
        Button("Plan a new trip") {
            isPresentingCreate = true
        }
        .buttonStyle(.primaryCapsule)
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
                    colorName: profile.avatarColor,
                    // P8a: threads the photo through — `AvatarStack` itself
                    // is the one place it actually renders.
                    avatarPath: profile.avatarPath
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
        let tripId = deleteLocally(trip)
        Task { await syncEngine?.enqueueDelete(table: .trips, rowId: tripId, tripId: tripId) }
    }

    /// The local-only half of `delete(_:)` above — the SwiftData delete +
    /// member/profile cascade, with no outbox enqueue of its own.
    ///
    /// F1 (reviewer, MED): `performMerge` below calls this directly (instead
    /// of `delete(_:)`) so the shell trip's `.trips` delete can be enqueued
    /// from the SAME sequential loop as its repoint upserts — `delete(_:)`'s
    /// own `Task { enqueueDelete }` would otherwise race that loop's `Task`,
    /// and `SyncStore` assigns `seq` in arrival order, so the delete could
    /// land before a repoint it should follow (a server-side `ON DELETE
    /// CASCADE` would then orphan whatever hadn't moved yet).
    @discardableResult
    private func deleteLocally(_ trip: Trip) -> UUID {
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
        return tripId
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

    // MARK: - P6.2 duplicate-trip merge (docs/UX_REDESIGN_ROADMAP.md)

    /// The 6s "stack settles" grace period `startMerge` owns — see that
    /// method's own doc comment for why this stands in for a literal
    /// post-hoc undo.
    private struct MergeCountdown {
        let shellId: UUID
        let survivorId: UUID
        let survivorTitle: String
        let task: Task<Void, Never>
        /// D2 fix (security+reviewer+tester, HIGH — dishonest UI): flips
        /// to `true` at the COMMIT BOUNDARY — the one synchronous instant,
        /// right before `performMerge` is even called, after which
        /// cancellation can no longer be honored (see `startMerge`'s own
        /// doc comment for exactly why). `cancelMerge`/`mergeCountdownOverlay`
        /// both consult this so a late tap can never again show "Merge
        /// cancelled" while the merge quietly finishes anyway.
        var isCommitted = false
    }

    /// Gates both the strip's visibility (`tripList`) and the action itself
    /// to a user who can edit BOTH trips AND whose merge won't strand a
    /// third party (D3, security+reviewer, MED — membership-blind auto-fire):
    /// `isOrganizer(of:)` on both (this app's existing "createdBy or
    /// organizer" check) is necessary but not sufficient — an organizer of
    /// BOTH trips could still delete a shell that a companion/viewer who
    /// ISN'T on the survivor depends on. Also true when the shell's only
    /// member is the acting user themselves (a solo trip nobody else was
    /// ever on) — evaluated without needing the survivor's own membership
    /// to be locally current, unlike the subset check. Recomputed fresh
    /// every call (reads live `tripMembers`/`authManager.userId`, nothing
    /// cached) so `startMerge` re-checking it "at action time" actually
    /// means something, not just at render time.
    private func canMergeTrips(_ shell: Trip, _ survivor: Trip) -> Bool {
        guard isOrganizer(of: shell), isOrganizer(of: survivor) else { return false }
        guard let userId = authManager.userId else {
            // Signed-out: every visible trip is local-only and necessarily
            // single-member (this device's own implicit organizer) — see
            // `isOrganizer`'s own doc comment. Nothing else to check.
            return true
        }
        let shellMemberIds = Set(tripMembers.filter { $0.tripId == shell.id }.map(\.userId))
        if shellMemberIds == [userId] { return true }
        let survivorMemberIds = Set(tripMembers.filter { $0.tripId == survivor.id }.map(\.userId))
        return shellMemberIds.isSubset(of: survivorMemberIds)
    }

    /// Tapping "Merge" doesn't merge immediately — it starts a 6s countdown
    /// (`mergeCountdownOverlay`) with an "Undo" escape hatch, and only
    /// performs the real merge once that window elapses uncancelled.
    /// `mergePendingConfirm`'s own confirmation dialog (D3) is the actual
    /// entry point now — reached only after the user confirms — but this
    /// re-checks `canMergeTrips` regardless, so nothing changing between
    /// "dialog shown" and "dialog confirmed" can slip through.
    ///
    /// Scope decision (per this task's own brief, stated here since it's a
    /// real design choice, not an obvious default): a literal post-hoc undo
    /// — restore the already-deleted shell trip, reverse every moved item/
    /// packing/profile's `trip_id` back, re-seat its `trip_members` row,
    /// and re-enqueue all of that against a server that may already have
    /// processed the original writes — is real distributed-systems
    /// complexity for a feature whose whole point is "I tapped the wrong
    /// thing a second ago." The mockup's own toast language ("the stack
    /// settles") already reads as a grace period rather than a reversible-
    /// after-the-fact action, so this implements exactly that: nothing
    /// touches the model or the network until the 6s elapse, so "Undo" is
    /// just cancelling a still-pending `Task` — trivially correct, with no
    /// reverse operation to get wrong.
    ///
    /// D2 fix — the seam: `Task.cancel()` only flips a flag; it can never
    /// abort code already running, so the ORIGINAL single `Task.isCancelled`
    /// check (right after the 6s sleep) left a real window open — a late
    /// Undo tap landing WHILE `performMerge`'s own awaits (two `pullTrip`s +
    /// a SwiftData save) were in flight cancelled the `Task` and showed
    /// "Merge cancelled," but `performMerge` kept running regardless and the
    /// completion toast overwrote it moments later. The commit boundary is
    /// the line right here, between the cancellation check and the call to
    /// `performMerge`: `isCommitted` flips to `true` SYNCHRONOUSLY (no
    /// `await` between the check and the flip, so there's no interleaving
    /// window), and `cancelMerge` refuses to do anything once it sees that
    /// flag — so a tap that lands in that same instant is guaranteed to see
    /// either a clean cancel (nothing started) or a no-op (already
    /// committed), never a false "cancelled."
    private func startMerge(shell: Trip, survivor: Trip) {
        guard mergeCountdown == nil else { return }
        guard canMergeTrips(shell, survivor) else { return }
        let shellId = shell.id
        let survivorId = survivor.id
        let survivorTitle = survivor.title
        let task = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled else { return }
            // The commit boundary (see this method's own doc comment) —
            // past this line, `cancelMerge` is a no-op.
            mergeCountdown?.isCommitted = true
            let didMerge = await performMerge(shellId: shellId, survivorId: survivorId)
            mergeCountdown = nil
            toast = didMerge
                ? "Merged into \(survivorTitle)"
                : "Couldn\u{2019}t merge \u{2014} try again."
        }
        mergeCountdown = MergeCountdown(shellId: shellId, survivorId: survivorId, survivorTitle: survivorTitle, task: task)
    }

    private func cancelMerge() {
        // D2 fix: once committed, cancellation is no longer authoritative —
        // refuse rather than lie ("Merge cancelled" while the merge quietly
        // finishes anyway).
        guard let pending = mergeCountdown, !pending.isCommitted else { return }
        pending.task.cancel()
        mergeCountdown = nil
        toast = "Merge cancelled"
    }

    /// The actual merge, run once `startMerge`'s countdown elapses
    /// uncancelled. `TripMerge.execute` does the SwiftData move (both
    /// trips pulled first — nt lesson YEFXVP, see that type's own doc
    /// comment); this method only supplies the context, the pull closures,
    /// and the outbox enqueue — same split `duplicateContent(from:into:)`
    /// above already uses for E2.
    @discardableResult
    private func performMerge(shellId: UUID, survivorId: UUID) async -> Bool {
        guard let moved = await TripMerge.execute(
            shellTripId: shellId, survivorTripId: survivorId, modelContext: modelContext,
            // Both sides pulled, not just the shell — either could be a
            // trip never opened this session (`TripMerge`'s own doc
            // comment), and the survivor's own local mirror needs to be
            // current too before the shell's rows land in it.
            ensureBothLoaded: {
                await syncEngine?.pullTrip(shellId)
                await syncEngine?.pullTrip(survivorId)
            }
        ) else {
            return false
        }

        let ops = MergeOutbox.performMergeOps(moved, shellId: shellId, survivorId: survivorId)

        // The shell's own items/packing/profiles have all moved away by
        // this point, so `deleteLocally(_:)`'s `tripProfiles` cascade loop
        // finds nothing left to double-delete on the profile side — it
        // still removes the shell's own `TripMember` row(s) (this merge's
        // permission gate already requires the acting user to be organizer
        // of both trips, so at minimum their own membership carries over
        // cleanly).
        //
        // F1 (reviewer, MED): `deleteLocally(_:)`, not `delete(_:)` — the
        // `.trips` delete `ops` already ends with is enqueued below, from
        // the SAME sequential loop as the repoint upserts, instead of
        // racing them from `delete(_:)`'s own separate `Task`.
        if let shellTrip = trips.first(where: { $0.id == shellId }) {
            deleteLocally(shellTrip)
        }
        Task {
            for op in ops {
                await enqueueMergedOp(op)
            }
        }
        return true
    }

    /// D5 (reviewer, MED): op shape/order comes from `MergeOutbox
    /// .performMergeOps` (`Models/MergeOutbox.swift`, mirrors this exact
    /// loop and is asserted byte-for-byte in `OutboxCoalescingTests`), not a
    /// hand-rolled loop re-typed here. F3 (reviewer, LOW-MED): `MergeOutboxOp`
    /// now carries each op's real DTO directly — no JSON encode/decode round
    /// trip, no `try?` silently dropping a case. F1 (reviewer, MED): this
    /// also replays the trailing `.deleteTrip` op, folded into the same
    /// sequential loop `performMerge` drives above instead of a second
    /// `Task`, so its `seq` always lands after every repoint upsert's.
    private func enqueueMergedOp(_ op: MergeOutboxOp) async {
        switch op {
        case .upsertItineraryItem(let dto):
            await syncEngine?.enqueueUpsert(table: .itineraryItems, rowId: dto.id, tripId: dto.tripId, payload: dto)
        case .upsertPackingItem(let dto):
            await syncEngine?.enqueueUpsert(table: .packingItems, rowId: dto.id, tripId: dto.tripId, payload: dto)
        case .upsertTripProfile(let dto):
            await syncEngine?.enqueueUpsert(table: .tripProfiles, rowId: dto.id, tripId: dto.tripId, payload: dto)
        case .deleteTrip(let id):
            await syncEngine?.enqueueDelete(table: .trips, rowId: id, tripId: id)
        case .unassignItemAssignee, .assignItemAssignee, .deleteTripProfile:
            break // `ShareTripView.mergeDuplicateProfilesOps`-only cases; `performMergeOps` never produces these.
        }
    }

    /// The countdown's own UI — same visual language as `ToastOverlay`'s
    /// plain toast (fixed `Palette.indigo` capsule, white text, so it reads
    /// consistently as "a toast" regardless of theme — white-on-indigo
    /// measures ~12.8:1, independently recomputed against `Tokens.swift`'s
    /// hex values; matches `HomeView`'s own `copyToNewTripSwipeAction` doc
    /// comment for this exact pairing) plus an "Undo" action neither
    /// `ToastOverlay` nor any other toast in this app supports.
    private var mergeCountdownOverlay: some View {
        // `.animation(value:)` lives on the OUTER `Group` (present whether
        // or not the countdown itself is), not inside the `if let` branch —
        // same reason `ToastOverlay.body` attaches its own `.animation
        // (value: message)` to the whole modifier's content rather than to
        // the conditional `Text`: an animation modifier scoped only to the
        // conditional branch never observes the transition INTO/OUT OF
        // that branch, just changes while already inside it.
        Group {
            if let mergeCountdown {
                // Same `AnyLayout` swap `TripCard.topLayout`/`DuplicateTripStrip
                // .layout` already use — the message and "Undo" have no room
                // to sit side by side at accessibility Dynamic Type sizes.
                let countdownLayout: AnyLayout = dynamicTypeSize.isAccessibilitySize
                    ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
                    : AnyLayout(HStackLayout(spacing: Spacing.md))
                countdownLayout {
                    Text("Merging into \(mergeCountdown.survivorTitle)\u{2026}")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(.white)
                    // D2 fix: once committed (past the point `cancelMerge`
                    // can still honor a tap), "Undo" is removed rather than
                    // left tappable-but-inert — an offer that can't do
                    // anything is its own kind of dishonest UI.
                    if !mergeCountdown.isCommitted {
                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer(minLength: Spacing.sm)
                        }
                        Button("Undo", action: cancelMerge)
                            .font(Typo.body(weight: .bold))
                            .foregroundStyle(.white)
                            .contentShape(Rectangle())
                            .frame(minHeight: 44)
                    }
                }
                .padding(.horizontal, Spacing.lg)
                .padding(.vertical, Spacing.md)
                .background(Palette.indigo, in: Capsule())
                .shadow(color: Palette.shadow.opacity(0.25), radius: 12, y: 6)
                .padding(.horizontal, Spacing.xl)
                .padding(.bottom, Spacing.xxl)
                .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                .task(id: mergeCountdown.shellId) {
                    // VoiceOver's only signal this started — same "an
                    // appearing/disappearing element needs an explicit
                    // announcement" rule `ToastOverlay`'s own `.task(id:)` uses.
                    AccessibilityNotification.Announcement(
                        "Merging into \(mergeCountdown.survivorTitle). Undo available for 6 seconds."
                    ).post()
                }
            }
        }
        .animation(Motion.m(Motion.standard, reduceMotion: reduceMotion), value: mergeCountdown != nil)
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
