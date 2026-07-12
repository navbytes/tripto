import SwiftData
import SwiftUI

/// The shared, assignable packing list (BUILD_PLAN.md §3.3, §5.4;
/// docs/TripAppFamily.jsx's `Packing` screen is the visual reference) —
/// rendered as `TripView`'s third content tab. Progress header,
/// grouped rows (checkbox/label/assignee), an add sheet, and role-gated
/// mutations (`PackingPermissions`) — everything here follows the same
/// "SwiftData write on the main context, then `SyncEngine.enqueue`" flow
/// every other mutation in the app uses.
struct PackingListView: View {
    let tripId: UUID
    /// The trip's `createdBy` — the signed-out user IS the local trip
    /// creator (see `TripView.canAddItems`'s doc comment), so this is
    /// their own uid from when they created the trip; the later push will
    /// satisfy RLS once they sign back in, same story as
    /// `AddItemSheet.tripCreatedBy`.
    let tripCreatedBy: UUID
    /// Backs the hero's scroll-driven collapse — this tab writes its own
    /// scroll offset directly into it via `.heroScrollTracking(tab:model:)`.
    /// See that modifier's doc comment (HeroCollapse.swift) for why it's a
    /// direct write rather than the `PreferenceKey` bubble-up this view used
    /// before.
    let heroScrollModel: HeroScrollModel
    /// Finding 2: true while this trip's first pull this session hasn't
    /// completed yet — see `TripView.awaitingFirstTripPull`'s doc comment.
    var isAwaitingFirstSync: Bool = false
    /// UX audit finding 3 (cross-screen): `item.id`s whose local write
    /// hasn't been confirmed by the server yet (`SyncStatus.pendingRowIds`
    /// via `TripView`) — threaded through so a not-yet-synced packing item
    /// gets the same `PendingSyncChip` treatment its Itinerary/Bookings
    /// siblings already have.
    var pendingRowIds: Set<UUID> = []
    /// UX audit finding 3: whether the device is currently offline —
    /// `TripView`'s `syncStatus.isOffline`, mirroring `ItineraryTabView`/
    /// `BookingsTabView`'s own `isOffline` so this tab's empty/unavailable
    /// copy can tell "haven't heard from the server since going offline"
    /// apart from "asked, and it failed."
    var isOffline: Bool = false
    /// UX audit finding 3: true when this trip's most recent `pullTrip(_:)`
    /// attempt this session failed — `SyncStatus.tripPullFailures` via
    /// `TripView`.
    var didLoadFail: Bool = false
    /// UX audit finding 3: retries this trip's pull — `TripView` wires this
    /// to `syncEngine.schedulePullTrip(trip.id)`, matching the sibling tabs.
    var onRetryLoad: (() -> Void)?
    /// UX audit finding 2 (cross-screen): backs pull-to-refresh on this tab
    /// — see `ItineraryTabView.onRefresh`'s doc comment for why this is a
    /// separate, awaited closure rather than reusing `onRetryLoad`.
    var onRefresh: (() async -> Void)?

    @Query private var packingItems: [PackingItem]
    @Query private var tripProfiles: [TripProfile]
    @Query private var members: [TripMember]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// D2 defect 4: `progressHeader`'s AX-size restack, same
    /// `isAccessibilitySize` convention as `TripCard.swift`/
    /// `TripView.tabBar()`.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Lock-glyph size next to the read-only notice's caption text — a bare
    /// `.font(.system(size:))` wouldn't scale with it (see the shared
    /// `@ScaledMetric` recipe used throughout Features/Trip).
    @ScaledMetric(relativeTo: .body) private var lockIconSize: CGFloat = 11
    /// Group-header glyph size, next to that header's own label.
    @ScaledMetric(relativeTo: .body) private var groupIconSize: CGFloat = 11

    /// TI-3: paste-import moved off this tab's FAB entirely — it's now
    /// `TripView.pasteImportPill`, the one consistent entry point shared by
    /// all three tabs (a UX audit found the FAB's old two-item
    /// confirmationDialog was itself one of several inconsistent paste
    /// doors; see that view's doc comment). The FAB goes back to a single
    /// action, so it opens the add-item form directly again, no menu.
    @State private var isPresentingAdd = false
    @State private var toast: String?
    @State private var reassigningItem: PackingItem?
    /// Finding 3: drives `PackingItemFormSheet` in edit mode — set from the
    /// row's leading swipe action, `nil` means the add sheet (driven by
    /// `isPresentingAdd`) is showing instead.
    @State private var editingItem: PackingItem?
    /// Finding 2: an always-on packed-to-bottom sort (`PackingGrouping`)
    /// already answers "what's left to pack"; this is the lightweight,
    /// opt-in complement for hiding packed items outright once most of the
    /// list is done.
    @State private var hidePacked = false
    /// UX audit finding 5: gates the swipe-delete confirmation — a shared
    /// list where you can delete items other people created deserves the
    /// same "destructive = confirm" contract as every other delete
    /// affordance in the app (Home's trip swipe, Booking detail's trash,
    /// `TripProfileFormSheet`'s remove).
    @State private var itemPendingDeletion: PackingItem?
    /// Haptics (award-polish pass): flipped on a successful add/update save
    /// and read only by the `.sensoryFeedback` below — fires on the save
    /// actually landing, not on the Save button tap itself.
    @State private var didSaveItem = false
    /// Flipped once a delete is confirmed (not on the swipe/dialog opening)
    /// — see `didSaveItem`'s doc comment for the same trigger-not-tap shape.
    @State private var didDeleteItem = false

    init(
        tripId: UUID, tripCreatedBy: UUID, heroScrollModel: HeroScrollModel, isAwaitingFirstSync: Bool = false,
        pendingRowIds: Set<UUID> = [], isOffline: Bool = false, didLoadFail: Bool = false,
        onRetryLoad: (() -> Void)? = nil, onRefresh: (() async -> Void)? = nil
    ) {
        self.tripId = tripId
        self.tripCreatedBy = tripCreatedBy
        self.heroScrollModel = heroScrollModel
        self.isAwaitingFirstSync = isAwaitingFirstSync
        self.pendingRowIds = pendingRowIds
        self.isOffline = isOffline
        self.didLoadFail = didLoadFail
        self.onRetryLoad = onRetryLoad
        self.onRefresh = onRefresh
        _packingItems = Query(filter: #Predicate<PackingItem> { $0.tripId == tripId })
        _tripProfiles = Query(filter: #Predicate<TripProfile> { $0.tripId == tripId })
        _members = Query(filter: #Predicate<TripMember> { $0.tripId == tripId })
    }

    private var myRole: TripRole? {
        guard let userId = authManager.userId else { return nil }
        return members.first { $0.userId == userId }?.role
    }

    /// Role gate for add/toggle/reassign (`PackingPermissions.canManage`) —
    /// convenience only (CLAUDE.md); RLS enforces the real boundary.
    ///
    /// Finding 1: adopts the exact "signed out ⇒ legitimately-permitted
    /// local creator" rule `TripView.canAddItems` already codifies (see its
    /// doc comment) — `PackingPermissions.canManage` alone reads `nil`
    /// `myRole` as "can't manage," which was demoting a signed-out local
    /// creator to read-only on their own trip's packing list.
    /// `PackingPermissions` itself is intentionally left untouched: it
    /// mirrors the live RLS policies, and "signed out" is a client-session
    /// concept RLS has no notion of — so the override lives here, at the
    /// view layer, not in that model.
    private var canManage: Bool {
        guard authManager.userId != nil else { return true }
        return PackingPermissions.canManage(role: myRole)
    }

    // Finding 2: the header's counts stay over the *full* list even when
    // `hidePacked` is on — only `groups` (what actually renders) is filtered.
    private var summary: PackingProgress.Summary { PackingProgress.summary(for: packingItems) }
    private var visibleItems: [PackingItem] { hidePacked ? packingItems.filter { !$0.isDone } : packingItems }
    private var groups: [(key: PackingGroupKey, items: [PackingItem])] { PackingGrouping.groups(for: visibleItems) }

    /// W1-D evidence-capture only — forces the settled-empty branch so
    /// `EmptyStateArt(scene: .packing)` can be screenshotted for real.
    /// `DemoSeeder`'s only seeded trip always has 12 packing items, and this
    /// environment has no touch-injection tool to build a fresh trip by
    /// hand — same `-uitestX` launch-argument convention as
    /// `HomeView`/`TripView`'s existing autopilot (chain: `-uitestAutoSignIn
    /// -uitestSeedIfEmpty -uitestOpenFirstTrip -uitestOpenPacking
    /// -uitestForceEmptyPacking`). Always `false` in Release.
    private var isForcedEmptyForScreenshot: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-uitestForceEmptyPacking")
        #else
        false
        #endif
    }

    var body: some View {
        Group {
            if packingItems.isEmpty || isForcedEmptyForScreenshot {
                emptyState
                    // See `ItineraryTabView`'s matching `.onAppear` for why
                    // an empty tab must explicitly reset its offset rather
                    // than leave a stale one from before it became empty.
                    .onAppear { heroScrollModel.offsets[.packing] = 0 }
            } else {
                VStack(spacing: 0) {
                    progressHeader
                    Rectangle().fill(Palette.mist).frame(height: 1)
                    list
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
        // Packing is a TripView tab now (not a pushed screen), and TripView
        // hides the nav bar for its gradient hero — so the add affordance is an
        // in-content FAB matching the itinerary tab, not a nav-bar button.
        .overlay(alignment: .bottomTrailing) {
            // `isForcedEmptyForScreenshot` excluded too — otherwise the
            // screenshot drill would show this floating FAB doubled up
            // alongside `emptyState`'s own CTA, which never happens in a
            // real empty state (there `packingItems.isEmpty` already gates
            // both).
            if canManage && !packingItems.isEmpty && !isForcedEmptyForScreenshot {
                Fab(action: { isPresentingAdd = true }, accessibilityLabel: "Add a packing item")
                    .padding(.trailing, Spacing.xl)
                    .padding(.bottom, Spacing.xxl)
            }
        }
        .sheet(isPresented: $isPresentingAdd) {
            PackingItemFormSheet(tripProfiles: tripProfiles) { label, groupKey, assigneeProfileId in
                addItem(label: label, groupKey: groupKey, assigneeProfileId: assigneeProfileId)
            }
        }
        // Finding 3: same form, driven by the item being edited — the sheet
        // decides add-vs-edit copy internally (see its `editing` init), and
        // the closure signature is unchanged so this call site just routes
        // to `updateItem` instead of `addItem`.
        .sheet(item: $editingItem) { item in
            PackingItemFormSheet(tripProfiles: tripProfiles, editing: item) { label, groupKey, assigneeProfileId in
                updateItem(item, label: label, groupKey: groupKey, assigneeProfileId: assigneeProfileId)
            }
        }
        .confirmationDialog(
            // Finding 7: "Assign to" for a never-assigned item, "Reassign
            // to" once it already has someone — read at render time so it
            // tracks whichever item triggered the dialog.
            reassigningItem?.assigneeProfileId == nil ? "Assign to" : "Reassign to",
            isPresented: Binding(
                get: { reassigningItem != nil },
                set: { isPresented in if !isPresented { reassigningItem = nil } }
            ),
            titleVisibility: .visible
        ) {
            // Finding 5: a checkmark suffix on the current assignee so the
            // dialog itself shows who's already on the hook, instead of
            // requiring a round-trip back to the row to check.
            Button("Unassigned" + (reassigningItem?.assigneeProfileId == nil ? "  \u{2713}" : "")) {
                if let item = reassigningItem { reassign(item, to: nil) }
                reassigningItem = nil
            }
            ForEach(tripProfiles) { profile in
                let isCurrent = reassigningItem?.assigneeProfileId == profile.id
                Button(profile.displayName + (isCurrent ? "  \u{2713}" : "")) {
                    if let item = reassigningItem { reassign(item, to: profile.id) }
                    reassigningItem = nil
                }
            }
            Button("Cancel", role: .cancel) { reassigningItem = nil }
        }
        // UX audit finding 5: swipe-delete now confirms first — same
        // "destructive = confirm" contract Home's trip swipe, Booking
        // detail's trash, and `TripProfileFormSheet`'s remove already use;
        // this was the one swipe/row delete in the app that skipped it.
        .confirmationDialog(
            "Remove this item?",
            isPresented: Binding(
                get: { itemPendingDeletion != nil },
                set: { isPresented in if !isPresented { itemPendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let item = itemPendingDeletion { delete(item) }
                itemPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) { itemPendingDeletion = nil }
        } message: {
            if let label = itemPendingDeletion?.label {
                Text("\u{201C}\(label)\u{201D} will be removed from the packing list for everyone on the trip.")
            }
        }
        // UX audit finding 8 (this tab): mirrors TripView.swift's own
        // finding-8 fix — this tab renders its own FAB in the same band, so
        // its toast needs the same constant FAB-clearance inset.
        .toastOverlay($toast, bottomInset: Fab.scrollClearance)
        // Haptics (award-polish pass): success on a landed add/update save,
        // warning on a confirmed delete — see `didSaveItem`/`didDeleteItem`.
        .sensoryFeedback(.success, trigger: didSaveItem)
        .sensoryFeedback(.warning, trigger: didDeleteItem)
        .task {
            #if DEBUG
            await applyUITestAutopilotIfNeeded()
            #endif
        }
    }

    // MARK: - Progress header (this milestone's brief: "'{done} of {total}
    // packed', %, gradient bar")

    /// D2 defect 4: at accessibility Dynamic Type sizes the fixed `HStack`
    /// below squeezed "{done} of {total} packed" (this row's biggest font,
    /// `Typo.display(20)`) between the Hide/Show-packed toggle and the
    /// percent label, truncating it to "5 of…". Same `isAccessibilitySize`
    /// `AnyLayout` swap `TripCard`/`BookingDetailView.actionRowLayout` use —
    /// stacks the three pieces instead of squeezing them side by side, so
    /// the count always gets the row's full width. Default rendering (the
    /// `HStackLayout` branch) is untouched.
    private var progressHeaderRowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xs))
            : AnyLayout(HStackLayout(alignment: .lastTextBaseline))
    }

    private var progressHeader: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            progressHeaderRowLayout {
                Text("\(summary.done) of \(summary.total) packed")
                    .font(Typo.display(20))
                    .foregroundStyle(Palette.ink)
                if !dynamicTypeSize.isAccessibilitySize {
                    Spacer(minLength: Spacing.sm)
                }
                // Finding 2: opt-in complement to the always-on
                // packed-to-bottom sort — only worth surfacing once there's
                // at least one packed item to hide.
                if summary.done > 0 {
                    Button {
                        if reduceMotion {
                            hidePacked.toggle()
                        } else {
                            withAnimation { hidePacked.toggle() }
                        }
                    } label: {
                        Text(hidePacked ? "Show packed" : "Hide packed")
                            .font(Typo.body(Typo.Size.caption, weight: .semibold))
                            // Finding 3 (sweep, same defect class):
                            // `amberInk` — see its doc comment in
                            // `PaletteExtras.swift`.
                            .foregroundStyle(hidePacked ? Palette.amberInk : Palette.slate)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, dynamicTypeSize.isAccessibilitySize ? 0 : Spacing.sm)
                }
                Text("\(summary.percent)%")
                    .font(Typo.body(Typo.Size.caption, weight: .bold))
                    // Finding 3 (sweep, same defect class): raw
                    // `Palette.amber` as foreground text measures ~2.3:1 on
                    // `Palette.paper` (fails AA).
                    .foregroundStyle(Palette.amberInk)
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.mist)
                    Capsule()
                        .fill(CoverGradient.dusk)
                        .frame(width: geometry.size.width * CGFloat(summary.percent) / 100)
                }
            }
            .frame(height: 8)

            // Finding 1: mirrors `BookingDetailView`'s read-only notice —
            // a plain-language signal (not just disabled-looking controls)
            // that this list can't be changed from this account/role.
            if !canManage && !packingItems.isEmpty {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: lockIconSize))
                        // Decorative — the adjacent sentence already says
                        // this list is read-only.
                        .accessibilityHidden(true)
                    Text("Only an organizer or companion can change the packing list.")
                }
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
                .padding(.top, Spacing.xs)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.lg)
    }

    // MARK: - Grouped list

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                ForEach(groups, id: \.key) { group in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        HStack(spacing: Spacing.xs) {
                            Image(systemName: group.key.symbolName)
                                .font(.system(size: groupIconSize, weight: .bold))
                                // Decorative — redundant with the label text
                                // right next to it.
                                .accessibilityHidden(true)
                            Text(group.key.displayName.uppercased())
                                .font(Typo.body(12, weight: .bold))
                                .tracking(0.5)
                        }
                        .foregroundStyle(Palette.slate)
                        // Matches the `.isHeader` trait `BookingsTabView`'s
                        // category headers and `ItineraryTabView`'s day
                        // headers already carry, so the headings rotor can
                        // jump group-to-group here too.
                        .accessibilityAddTraits(.isHeader)

                        VStack(spacing: Spacing.sm) {
                            ForEach(group.items) { item in
                                PackingRow(
                                    item: item,
                                    canManage: canManage,
                                    tripProfiles: tripProfiles,
                                    // Finding 1: same signed-out-creator override `canManage`
                                    // already applies — without it a signed-out creator could
                                    // toggle/reassign/edit but not delete their own item.
                                    canDelete: authManager.userId == nil
                                        || PackingPermissions.canDelete(item: item, role: myRole, userId: authManager.userId),
                                    // UX audit finding 3: same dashed-border/
                                    // chip treatment `BookingRow`/
                                    // `TimelineCardRow` already give a
                                    // not-yet-synced row.
                                    isPending: pendingRowIds.contains(item.id),
                                    onToggle: { toggleDone(item) },
                                    onReassign: { reassigningItem = item },
                                    onEdit: { editingItem = item },
                                    // UX audit finding 5: routes through a
                                    // confirmation instead of deleting on the
                                    // swipe tap alone — see
                                    // `itemPendingDeletion`'s doc comment.
                                    onDelete: { itemPendingDeletion = item }
                                )
                            }
                        }
                    }
                }
            }
            .heroScrollTracking(tab: .packing, model: heroScrollModel)
            .padding(Spacing.xl)
            // UX audit finding 4: matches the FAB clearance the itinerary/
            // bookings scroll views use — this tab's own FAB sits in the
            // same band, so its last row deserves the same headroom.
            .padding(.bottom, Fab.scrollClearance)
        }
        .coordinateSpace(.named(HeroCollapse.scrollSpace(for: .packing)))
        // UX audit finding 2: manual pull-to-refresh, matching Home and this
        // tab's Itinerary/Bookings siblings.
        .refreshable { await onRefresh?() }
    }

    // MARK: - Empty state (§6.6: invitation copy, not blank)

    private var emptyState: some View {
        VStack(spacing: Spacing.lg) {
            Spacer()
            if isAwaitingFirstSync {
                // Finding 2: a freshly-claimed (or just-opened) trip's
                // packing list can't yet be told apart from a genuinely
                // empty one while its first pull is still in flight — this
                // neutral placeholder (no CTA, no claim either way) mirrors
                // `HomeView.initialLoadState`'s "Checking for your trips…"
                // instead of asserting "start the list" before the answer
                // is known.
                ProgressView()
                Text("Checking the packing list\u{2026}")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
            } else if !canManage && (isOffline || didLoadFail) {
                // UX audit finding 3: mirrors `BookingsTabView.unavailableState`
                // — a viewer whose packing list loaded empty *and* the load
                // itself is suspect (offline, or this trip's last pull
                // failed) shouldn't read the settled "no one's added
                // anything" copy as fact; `!canManage` stands in for the
                // viewer check the same way `onAdd == nil` does over there
                // (an editor's "add what this trip needs" invitation stays
                // correct either way).
                unavailableState
            } else {
                // W1-D: EmptyStateArt replaces the old bare glyph here —
                // decorative, fixed size, accessibilityHidden internally;
                // the headline right below already carries the message.
                EmptyStateArt(scene: .packing)
                VStack(spacing: Spacing.xs) {
                    Text("Start the family packing list")
                        .font(Typo.display(Typo.Size.title))
                        .foregroundStyle(Palette.ink)
                        .multilineTextAlignment(.center)
                    Text(
                        canManage
                            ? "Passports, the car seat, chargers everyone forgets \u{2014} add what this trip needs."
                            // Finding 6: neutral, non-misattributing —
                            // §6.6's "empty screens are invitations, not
                            // blame" (the organizer isn't necessarily the
                            // one who'd add packing items).
                            : "No one\u{2019}s added anything to the packing list yet."
                    )
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
                    .multilineTextAlignment(.center)
                }
                .padding(.horizontal, Spacing.xl)
                if canManage {
                    Button {
                        isPresentingAdd = true
                    } label: {
                        Text("Add an item")
                            .font(Typo.body(weight: .semibold))
                            .foregroundStyle(Palette.onAmber)
                            .padding(.horizontal, Spacing.xl)
                            .padding(.vertical, Spacing.md)
                            .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor
                            .contentShape(Capsule())
                            .background(Palette.amber, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    // TI-3: no separate "Or paste a list instead" fallback
                    // needed here anymore — `TripView.pasteImportPill` is
                    // always visible above the tab content regardless of
                    // item count, which is what this fallback used to exist
                    // to work around (the FAB itself only rendered once the
                    // list was non-empty).
                }
            }
            Spacer()
            Spacer()
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// UX audit finding 3: modeled on `BookingsTabView.unavailableState`,
    /// sized to this tab's simpler empty-state shell.
    private var unavailableState: some View {
        VStack(spacing: Spacing.md) {
            // Decorative — see the matching icon in `emptyState` above.
            Image(systemName: "bag.badge.plus")
                .font(.system(size: 36))
                .foregroundStyle(Palette.slate)
                .accessibilityHidden(true)
            Text(isOffline ? "Packing list hasn\u{2019}t loaded yet" : "Couldn\u{2019}t load the packing list")
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
                .multilineTextAlignment(.center)
            Text(
                isOffline
                    ? "You\u{2019}re offline \u{2014} the packing list will appear once you\u{2019}re back online."
                    : "Check your connection and try again."
            )
            .font(Typo.body())
            .foregroundStyle(Palette.slate)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xxl)
            // Offline has nothing to retry — the pull resumes the moment
            // connectivity returns, so a CTA here would just be a button
            // that does nothing new.
            if !isOffline {
                Button(action: { onRetryLoad?() }) {
                    Text("Try again")
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

    // MARK: - Mutations

    private func toggleDone(_ item: PackingItem) {
        guard canManage else { return }
        // Finding 2: so a checked item visibly sinks to the bottom of its
        // group (`PackingGrouping.groups(for:)`'s new packed-to-bottom
        // sort) instead of just snapping there.
        if reduceMotion {
            item.isDone.toggle()
        } else {
            withAnimation {
                item.isDone.toggle()
            }
        }
        item.updatedAt = .now
        item.updatedBy = authManager.userId
        try? modelContext.save()
        enqueue(item)
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func reassign(_ item: PackingItem, to profileId: UUID?) {
        guard canManage else { return }
        item.assigneeProfileId = profileId
        item.updatedAt = .now
        item.updatedBy = authManager.userId
        try? modelContext.save()
        enqueue(item)
        // Finding 9: parity with `addItem`'s toast + `toggleDone`'s haptic —
        // reassigning previously gave no feedback at all.
        let firstName = profileId
            .flatMap { id in tripProfiles.first { $0.id == id } }
            .map { $0.displayName.split(separator: " ").first.map(String.init) ?? $0.displayName }
        toast = firstName.map { "Assigned to \($0)" } ?? "Marked unassigned"
        UISelectionFeedbackGenerator().selectionChanged()
    }

    /// Finding 3: preserves `isDone`/`assigneeProfileId` — a label/group
    /// typo fix is one sync op instead of the old delete-and-re-add, which
    /// silently dropped both.
    private func updateItem(_ item: PackingItem, label: String, groupKey: PackingGroupKey, assigneeProfileId: UUID?) {
        guard canManage, !label.isEmpty else { return }
        item.label = label
        item.groupKeyRaw = groupKey.rawValue
        item.assigneeProfileId = assigneeProfileId
        item.updatedAt = .now
        item.updatedBy = authManager.userId
        try? modelContext.save()
        enqueue(item)
        didSaveItem.toggle()
    }

    /// Finding 1: dropped the `authManager.userId` hard guard — it made
    /// this silently no-op for a signed-out local creator (`canManage`
    /// already grants them the add). `createdBy` falls back to
    /// `tripCreatedBy` (the signed-out creator's own uid) when there's no
    /// signed-in session, and the toast is qualified so the fact that it
    /// hasn't synced anywhere yet is honest, not silent.
    /// Nit: `announceIndividually` lets a bulk caller (paste-import's
    /// confirm loop) suppress this call's own per-item toast and show one
    /// counted summary instead once the whole batch lands — see that call
    /// site's doc comment.
    private func addItem(
        label: String, groupKey: PackingGroupKey, assigneeProfileId: UUID?, announceIndividually: Bool = true
    ) {
        guard canManage, !label.isEmpty else { return }
        PackingItem.insert(
            label: label, groupKey: groupKey, assigneeProfileId: assigneeProfileId,
            tripId: tripId, createdBy: authManager.userId ?? tripCreatedBy,
            modelContext: modelContext, syncEngine: syncEngine
        )
        // Haptics: gated the same as the toast below — a bulk paste-import
        // add loop stays quiet per item (one buzz per pasted row would be
        // noise), same reasoning as its suppressed per-item toast.
        guard announceIndividually else { return }
        didSaveItem.toggle()
        toast = authManager.userId == nil
            ? "Added to packing list \u{2014} you\u{2019}re signed out, so it won\u{2019}t sync until you sign back in."
            : "Added to packing list"
    }

    private func delete(_ item: PackingItem) {
        let rowId = item.id
        modelContext.delete(item)
        try? modelContext.save()
        Task { await syncEngine?.enqueueDelete(table: .packingItems, rowId: rowId, tripId: tripId) }
        // Finding 9: parity with `addItem`'s toast + `toggleDone`'s haptic —
        // deleting previously gave no feedback at all.
        toast = "Removed from packing list"
        UISelectionFeedbackGenerator().selectionChanged()
        didDeleteItem.toggle()
    }

    private func enqueue(_ item: PackingItem) {
        let dto = item.toDTO()
        let rowId = item.id
        Task { await syncEngine?.enqueueUpsert(table: .packingItems, rowId: rowId, tripId: tripId, payload: dto) }
    }

    // MARK: - DEBUG verify-drill autopilot

    #if DEBUG
    /// M4 verify drill: toggles one seeded (not-yet-done) packing item and
    /// assigns another seeded (not-yet-assigned) one to "Meera" — proves
    /// both a toggle and an assignment reach the server, with no GUI tap
    /// automation available in this environment (see `WelcomeView`/
    /// `HomeView`'s matching `-uitest…` doc comments). Matched by
    /// `DemoSeeder`'s exact labels rather than "first"/"second" — `@Query`
    /// carries no explicit sort here, so positional indexing into
    /// `packingItems` would be unpredictable.
    private func applyUITestAutopilotIfNeeded() async {
        guard ProcessInfo.processInfo.arguments.contains("-uitestTogglePacking") else { return }
        if let boardingPasses = packingItems.first(where: { $0.label == "Boarding passes" }) {
            toggleDone(boardingPasses)
        }
        if let charger = packingItems.first(where: { $0.label == "Portable phone charger" }),
            charger.assigneeProfileId == nil,
            let meera = tripProfiles.first(where: { $0.displayName.hasPrefix("Meera") }) {
            reassign(charger, to: meera.id)
        }
    }
    #endif
}

/// One packing-list row: checkbox/label toggle, assignee chip, and the
/// trailing delete / leading edit swipe actions — extracted opportunistically
/// (UX audit finding 8, deferred as its own formal fix per iPhone-first) once
/// findings 1/3/4 already touched every part of it. A plain callback-driven
/// leaf, same shape as `PackingItemFormSheet`, so `PackingListView` still
/// owns all the SwiftData/sync state.
private struct PackingRow: View {
    let item: PackingItem
    let canManage: Bool
    let tripProfiles: [TripProfile]
    let canDelete: Bool
    /// UX audit finding 3 (cross-screen): true while this row's local write
    /// hasn't been confirmed by the server yet — same signal
    /// `BookingRow`/`TimelineCardRow` already render a chip for.
    let isPending: Bool
    let onToggle: () -> Void
    let onReassign: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    /// The checkbox is a fixed-size container around its own checkmark
    /// glyph, not just a bare icon — both need to grow together (per the
    /// shared `@ScaledMetric` recipe) or the box reads as shrinking next to
    /// the label as Dynamic Type scales up.
    @ScaledMetric(relativeTo: .body) private var checkboxSide: CGFloat = 24
    @ScaledMetric(relativeTo: .body) private var checkmarkSize: CGFloat = 12
    /// D2 defect 4: `rowLayout`'s AX-size restack, same `isAccessibilitySize`
    /// convention as `TripCard.swift`/`TripView.tabBar()`.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// At accessibility Dynamic Type sizes the fixed `HStack` below squeezed
    /// `item.label` between the (also-scaling) checkbox and the assignee
    /// chip until even 2 lines couldn't hold it, truncating mid-word
    /// ("Boar"/"din…"). Same `isAccessibilitySize` `AnyLayout` swap
    /// `TripCard`/`BookingDetailView.actionRowLayout` use: the reassign
    /// button drops to its own row below instead of sharing this one, so
    /// the toggle button's checkbox+label pairing gets the row's full width.
    /// Default rendering (the `HStackLayout` branch) is untouched.
    private var rowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.sm))
            : AnyLayout(HStackLayout(spacing: Spacing.md))
    }

    var body: some View {
        rowLayout {
            Button(action: onToggle) {
                HStack(spacing: Spacing.md) {
                    checkbox
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.label)
                            .font(Typo.body(Typo.Size.body, weight: .semibold))
                            .foregroundStyle(item.isDone ? Palette.slate : Palette.ink)
                            .strikethrough(item.isDone)
                            // Finding (D2 defect 4): unlimited at AX sizes —
                            // `rowLayout` above already gives this row's
                            // label the full row width there, same relief
                            // `BookingDetailView.actionLabel` uses.
                            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                        if isPending { PendingSyncChip() }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!canManage)
            // Finding 1: dims the checkbox/label so it no longer *looks*
            // tappable for a read-only viewer — `.disabled` above is the
            // real gate, this is just matching affordance to reality.
            .opacity(canManage ? 1 : 0.5)
            // Finding 4: VoiceOver only heard "Button" with no indication of
            // what it toggled or its current state.
            .accessibilityLabel(item.label)
            .accessibilityValue(item.isDone ? "Packed" : "Not packed")
            .accessibilityAddTraits(item.isDone ? [.isSelected] : [])
            .accessibilityHint(accessibilityHintText)

            Button(action: onReassign) {
                assigneeChip
            }
            .buttonStyle(.plain)
            .disabled(!canManage)
            .opacity(canManage ? 1 : 0.5)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay {
            // UX audit finding 3: same dashed-border treatment `BookingRow`/
            // `TimelineCardRow` use for a not-yet-synced row.
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                .strokeBorder(
                    isPending ? Palette.slate.opacity(0.35) : Palette.mist,
                    style: StrokeStyle(lineWidth: isPending ? 1.25 : 1, dash: isPending ? [5, 4] : [])
                )
        }
        .opacity(item.isDone ? 0.65 : 1)
        .swipeActions(edge: .trailing) {
            if canDelete {
                Button("Delete", role: .destructive, action: onDelete)
            }
        }
        .swipeActions(edge: .leading) {
            // Finding 3: a typo/wrong-category fix no longer has to go
            // through delete-and-re-add.
            if canManage {
                Button("Edit", action: onEdit).tint(Palette.indigo)
            }
        }
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(item.isDone ? CategoryColor.activity.fg : Color.clear)
            .frame(width: checkboxSide, height: checkboxSide)
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(item.isDone ? Color.clear : Palette.mist, lineWidth: 2)
            }
            .overlay {
                if item.isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: checkmarkSize, weight: .bold))
                        .foregroundStyle(.white)
                }
            }
    }

    /// UX audit finding 3: combines `canManage`'s existing toggle hint with
    /// a pending-sync note — a single hint string, since `.accessibilityHint`
    /// calls don't stack (the last one applied wins).
    private var accessibilityHintText: String {
        var parts: [String] = []
        if canManage { parts.append("Double tap to mark packed") }
        if isPending { parts.append("Waiting to sync") }
        return parts.joined(separator: ", ")
    }

    private var assigneeChip: some View {
        let profile = item.assigneeProfileId.flatMap { id in tripProfiles.first { $0.id == id } }
        return HStack(spacing: 6) {
            // Avatar bubble — deliberately fixed size (matches every other
            // avatar circle in the app, e.g. `PersonFilterBar`'s chips,
            // none of which scale with Dynamic Type either); the name text
            // beside it carries the scaling information.
            Circle()
                .fill(profile.map { AvatarColor.color(named: $0.avatarColor) } ?? Palette.mist)
                .frame(width: 22, height: 22)
                .overlay {
                    if let profile {
                        Text(initials(from: profile.displayName))
                            .font(Typo.body(10, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: "person.fill.questionmark")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.slate)
                            .accessibilityHidden(true)
                    }
                }
            Text(profile.map { firstName(from: $0.displayName) } ?? "Unassigned")
                .font(Typo.body(11.5, weight: .semibold))
                .foregroundStyle(Palette.slate)
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, Spacing.sm)
        .padding(.vertical, 4)
        .background(Palette.paper, in: Capsule())
    }

    private func firstName(from displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }

    private func initials(from displayName: String) -> String {
        firstName(from: displayName).prefix(1).uppercased()
    }
}

/// Add-item sheet (this milestone's brief: "Add-item affordance (label +
/// group + optional assignee)"). A plain closure callback (`onSave`), not a
/// direct SwiftData/sync dependency, so this stays a dumb form the same way
/// `RolePickerSheet` (ShareTripView.swift) does.
private struct PackingItemFormSheet: View {
    let tripProfiles: [TripProfile]
    /// Finding 3: reused for edit — `nil` (the default) is the add flow this
    /// sheet already had; a non-nil item seeds the form's initial state and
    /// switches the header/button copy below. `onSave`'s signature is
    /// unchanged either way; the caller (`PackingListView`) decides whether
    /// that's an add or an update from which state var drove the sheet.
    var editing: PackingItem?
    let onSave: (_ label: String, _ groupKey: PackingGroupKey, _ assigneeProfileId: UUID?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @State private var groupKey: PackingGroupKey
    @State private var assigneeProfileId: UUID?
    /// `groupTile`'s icon, stacked above its own label — see the shared
    /// `@ScaledMetric` recipe used throughout Features/Trip.
    @ScaledMetric(relativeTo: .body) private var groupTileIconSize: CGFloat = 15
    /// UX audit finding 4: gates the "Discard changes?" confirmation on
    /// Cancel/swipe-dismiss — the same guard `TripFormView`/`AddItemSheet`
    /// already apply, extended to this sheet and `TripProfileFormSheet`,
    /// the two form sheets that had been skipping it.
    @State private var showDiscardConfirm = false

    /// The label/group/assignee this sheet opened with, so `hasChanges` can
    /// tell an untouched form from a dirty one — same role as
    /// `TripFormView.initialValues`.
    private let initialLabel: String
    private let initialGroupKey: PackingGroupKey
    private let initialAssigneeProfileId: UUID?

    init(
        tripProfiles: [TripProfile], editing: PackingItem? = nil,
        onSave: @escaping (_ label: String, _ groupKey: PackingGroupKey, _ assigneeProfileId: UUID?) -> Void
    ) {
        self.tripProfiles = tripProfiles
        self.editing = editing
        self.onSave = onSave
        _label = State(initialValue: editing?.label ?? "")
        _groupKey = State(initialValue: editing?.groupKey ?? .shared)
        _assigneeProfileId = State(initialValue: editing?.assigneeProfileId)
        initialLabel = editing?.label ?? ""
        initialGroupKey = editing?.groupKey ?? .shared
        initialAssigneeProfileId = editing?.assigneeProfileId
    }

    private var isValid: Bool { !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// UX audit finding 4: whether any field has moved from what the sheet
    /// opened with.
    private var hasChanges: Bool {
        label != initialLabel || groupKey != initialGroupKey || assigneeProfileId != initialAssigneeProfileId
    }

    private func cancelTapped() {
        if hasChanges {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Palette.mist).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        FormTextField(label: "Item", text: $label, placeholder: "Passports, car seat, chargers\u{2026}")

                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            Text("Group")
                                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                                .foregroundStyle(Palette.slate)
                            HStack(spacing: Spacing.sm) {
                                ForEach(PackingGrouping.order, id: \.self) { key in
                                    groupTile(key)
                                }
                            }
                        }

                        if !tripProfiles.isEmpty {
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text("Assign to (optional)")
                                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                                    .foregroundStyle(Palette.slate)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: Spacing.sm) {
                                        assigneeTile(nil, label: "Unassigned", colorName: nil)
                                        ForEach(tripProfiles) { profile in
                                            assigneeTile(profile.id, label: firstName(from: profile.displayName), colorName: profile.avatarColor)
                                        }
                                    }
                                }
                            }
                        }

                        Button {
                            onSave(label.trimmingCharacters(in: .whitespacesAndNewlines), groupKey, assigneeProfileId)
                            dismiss()
                        } label: {
                            Text(editing == nil ? "Add to packing list" : "Save changes")
                                .font(Typo.body(weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .foregroundStyle(isValid ? Palette.onAmber : Palette.slate)
                                .padding(.vertical, Spacing.md)
                                .background(
                                    isValid ? Palette.amber : Palette.mist, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .disabled(!isValid)
                        .padding(.top, Spacing.xs)
                    }
                    .padding(Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        // UX audit finding 4: same guard `TripFormView`/`AddItemSheet` use —
        // a stray swipe-down while naming a packing item used to silently
        // lose the input.
        .background(
            SheetDismissAttemptObserver {
                if hasChanges { showDiscardConfirm = true }
            }
        )
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack {
            Button("Cancel", action: cancelTapped)
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.slate)
                // Finding 3b: 44pt hit band (§6.5) — same
                // PersonFilterBar.swift compensation move as below.
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            Spacer()
            Text(editing == nil ? "Add packing item" : "Edit packing item")
                .font(Typo.body(weight: .bold))
                .foregroundStyle(Palette.ink)
            Spacer()
            Text("Cancel").font(Typo.body(weight: .semibold)).opacity(0) // balances the leading button
                .frame(minHeight: 44)
        }
        .padding(.horizontal, Spacing.lg)
        // Finding 3b: trimmed from Spacing.md/.sm to .xs/.xs — the Cancel
        // button's new 44pt hit band grows the row, so this keeps the
        // header's total height roughly unchanged (PersonFilterBar.swift's
        // same trade-off).
        .padding(.top, Spacing.xs)
        .padding(.bottom, Spacing.xs)
    }

    private func groupTile(_ key: PackingGroupKey) -> some View {
        let isOn = groupKey == key
        return Button {
            groupKey = key
        } label: {
            VStack(spacing: 4) {
                Image(systemName: key.symbolName)
                    .font(.system(size: groupTileIconSize, weight: .medium))
                    // Decorative — the label right below already names the group.
                    .accessibilityHidden(true)
                Text(key.displayName).font(Typo.body(10.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? CategoryColor.activity.fg : Palette.slate)
            .frame(maxWidth: .infinity)
            .padding(.vertical, Spacing.sm)
            .background(isOn ? CategoryColor.activity.soft : Palette.elevated, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isOn ? CategoryColor.activity.fg : Palette.mist, lineWidth: 1.25)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func assigneeTile(_ id: UUID?, label text: String, colorName: String?) -> some View {
        let isOn = assigneeProfileId == id
        return Button {
            assigneeProfileId = id
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(colorName.map { AvatarColor.color(named: $0) } ?? Palette.mist)
                    .frame(width: 20, height: 20)
                    .overlay {
                        if colorName != nil {
                            Text(text.prefix(1).uppercased())
                                .font(Typo.body(9, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                Text(text).font(Typo.body(12.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? .white : Palette.slate)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + 2)
            .background(isOn ? Palette.indigo : Palette.elevated, in: Capsule())
            .overlay {
                Capsule().stroke(isOn ? Color.clear : Palette.mist, lineWidth: 1)
            }
            // Finding 3a: same 44pt hit band as PersonFilterBar's chips
            // (§6.5) — visuals unchanged, hit area compliant.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func firstName(from displayName: String) -> String {
        displayName.split(separator: " ").first.map(String.init) ?? displayName
    }
}
