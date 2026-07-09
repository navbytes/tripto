import SwiftUI

/// The "Bookings" sub-tab (BUILD_PLAN.md §4.2 tabs) — every item that has a
/// confirmation code, flattened and grouped by category, so a traveler can
/// find "the flight confirmation" without scrolling the full day-by-day
/// timeline. Tapping a row opens the same `BookingDetailView` the timeline
/// tab's cards do, via the shared `ItemRoute` navigation destination.
struct BookingsTabView: View {
    let items: [ItineraryItem]
    /// Backs the hero's scroll-driven collapse — this tab writes its own
    /// scroll offset directly into it via `.heroScrollTracking(tab:model:)`.
    /// See that modifier's doc comment (HeroCollapse.swift) for why it's a
    /// direct write rather than the `PreferenceKey` bubble-up this view used
    /// before.
    let heroScrollModel: HeroScrollModel
    /// Invokes `TripView`'s `AddItemSheet` presentation (finding 6) — `nil`
    /// for viewers, who get read-only copy instead of a routing affordance.
    /// Backs the empty state's CTA; `TripView` also shows the shared FAB on
    /// this tab for editors (UX audit finding 5), so this isn't the only
    /// entry point once there's at least one booking on screen.
    var onAdd: (() -> Void)? = nil
    /// Finding 2: true while this trip's first pull this session hasn't
    /// completed yet — see `TripView.awaitingFirstTripPull`'s doc comment.
    var isAwaitingFirstSync: Bool = false
    /// UX audit finding 3: `TimelineDayModel`-style pending set — `item.id`s
    /// whose local write hasn't been confirmed by the server yet
    /// (`SyncStatus.pendingRowIds` via `TripView`), threaded through so a
    /// not-yet-synced booking gets the same dashed-border/`PendingSyncChip`
    /// treatment as its Itinerary-tab card, a scroll away.
    var pendingRowIds: Set<UUID> = []
    /// UX audit finding 1: whether the device is currently offline —
    /// `TripView`'s `syncStatus.isOffline`, threaded through so
    /// `unavailableState` can tell "haven't heard from the server since
    /// going offline" apart from "asked, and it failed" and phrase the
    /// empty state's copy accordingly.
    var isOffline: Bool = false
    /// UX audit finding 1: true when this trip's most recent `pullTrip(_:)`
    /// attempt this session failed — `SyncStatus.tripPullFailures` via
    /// `TripView`. Distinguishes a settled-but-failed load from a settled
    /// -and-genuinely-empty one, so a viewer whose trip cached but whose
    /// bookings didn't never sees the false "bookings will collect here"
    /// invitation.
    var didLoadFail: Bool = false
    /// UX audit finding 1: retries this trip's pull — `TripView` wires this
    /// to `syncEngine.schedulePullTrip(trip.id)`. `nil` only in previews/
    /// tests that don't wire a live sync engine.
    var onRetryLoad: (() -> Void)? = nil

    /// UX audit finding 5: relevance-aware ordering within each category —
    /// each category's items are split into current/upcoming (sorted
    /// ascending) followed by past (also sorted ascending), instead of one
    /// flat ascending sort, so the next-needed leg surfaces above an
    /// already-used outbound on a multi-leg trip. Uses the same
    /// `item.endsAt ?? item.startsAt` effective-end convention already used
    /// in `TimelineModels`/`BookingDetailView`, so an in-progress flight
    /// counts as current, not past. BUILD_PLAN doesn't specify a Bookings
    /// sort order; this is a judgment call in service of the tab's quick
    /// -lookup purpose, kept deliberately minimal (no new sort UI).
    private var groups: [(category: ItemCategory, items: [ItineraryItem])] {
        let now = Date.now
        let withConfirmation = items.filter { !($0.confirmation ?? "").isEmpty }
        let grouped = Dictionary(grouping: withConfirmation, by: \.category)
        return ItemCategory.allCases.compactMap { category in
            guard let group = grouped[category], !group.isEmpty else { return nil }
            let current = group.filter { ($0.endsAt ?? $0.startsAt) >= now }.sorted { $0.startsAt < $1.startsAt }
            let past = group.filter { ($0.endsAt ?? $0.startsAt) < now }.sorted { $0.startsAt < $1.startsAt }
            return (category, current + past)
        }
    }

    var body: some View {
        Group {
            if groups.isEmpty {
                emptyState
                    // See `ItineraryTabView`'s matching `.onAppear` for why
                    // an empty tab must explicitly reset its offset rather
                    // than leave a stale one from before it became empty.
                    .onAppear { heroScrollModel.offsets[.bookings] = 0 }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Spacing.lg) {
                        ForEach(groups, id: \.category) { group in
                            VStack(alignment: .leading, spacing: Spacing.sm) {
                                Text(group.category.displayName.uppercased())
                                    .font(Typo.body(11, weight: .bold))
                                    .foregroundStyle(Palette.slate)
                                    .tracking(0.5)
                                    .padding(.horizontal, Spacing.lg)
                                    // Finding 6: lets the VoiceOver headings
                                    // rotor jump category-to-category on a
                                    // Bookings tab with many groups, matching
                                    // `ItineraryTabView.dayHeader`.
                                    .accessibilityAddTraits(.isHeader)

                                VStack(spacing: Spacing.sm) {
                                    ForEach(group.items) { item in
                                        BookingRow(item: item, isPending: pendingRowIds.contains(item.id))
                                    }
                                }
                                .padding(.horizontal, Spacing.lg)
                            }
                        }
                    }
                    .heroScrollTracking(tab: .bookings, model: heroScrollModel)
                    .padding(.vertical, Spacing.lg)
                    .padding(.bottom, Fab.scrollClearance)
                }
                .coordinateSpace(.named(HeroCollapse.scrollSpace(for: .bookings)))
            }
        }
        .background(Palette.paper)
    }

    // Finding 6 (§6.6 invitation copy): the old state just described what
    // would happen ("confirmation codes you add will collect here") without
    // giving the organizer a way to make it happen — a dead end on the one
    // tab whose entire purpose is "find the confirmation code." An editor
    // gets an invitation with a route; a viewer gets the honest read-only
    // version of the same sentence.
    //
    // UX audit finding 1: a new `unavailableState` branch sits between the
    // loading branch and the settled branch, gated `onAdd == nil &&
    // (isOffline || didLoadFail)`. This file has no person-filter branch
    // (unlike `ItineraryTabView`), so `onAdd`'s nil-ness alone stands in for
    // the viewer/editor check the doc comment above already uses it for —
    // the editor's settled-empty copy stays an invitation, not an assertion
    // about the trip's contents, so it's still correct mid-outage and is
    // deliberately left in the `else` branch.
    private var emptyState: some View {
        VStack(spacing: Spacing.md) {
            Spacer()
            if isAwaitingFirstSync {
                // Finding 2: a freshly-claimed (or just-opened) trip's
                // bookings can't yet be told apart from genuinely having
                // none while its first pull is still in flight — "Add your
                // first booking" would be a claim ("first") we can't make
                // yet, so the CTA is hidden until the answer is known.
                ProgressView()
                Text("Checking this trip\u{2019}s bookings\u{2026}")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
            } else if onAdd == nil && (isOffline || didLoadFail) {
                unavailableState
            } else {
                Image(systemName: "ticket")
                    .font(.system(size: 34))
                    .foregroundStyle(Palette.slate)
                Text(
                    onAdd != nil
                        ? "Add a flight or stay with its confirmation code \u{2014} bookings collect here automatically."
                        : "Bookings the organizers add will collect here."
                )
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Spacing.xxl)
                if let onAdd {
                    Button(action: onAdd) {
                        Text("Add your first booking")
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
            Spacer()
            Spacer()
        }
    }

    /// UX audit finding 1: shown instead of the settled-empty "bookings will
    /// collect here" copy to a viewer (`onAdd == nil`) whose trip loaded with
    /// no bookings in it *and* the load itself is suspect — either the
    /// device is offline (`isOffline`) or this trip's last pull attempt
    /// failed (`didLoadFail`). Without this branch, that viewer would read a
    /// guess dressed up as a fact: the organizer may well have added
    /// confirmations that just haven't arrived on this device yet. Modeled
    /// on `ItineraryTabView.unavailableState` but sized to this file's
    /// simpler empty-state shell.
    private var unavailableState: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "ticket")
                .font(.system(size: 34))
                .foregroundStyle(Palette.slate)
            Text(isOffline ? "Bookings haven\u{2019}t loaded yet" : "Couldn\u{2019}t load this trip\u{2019}s bookings")
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
                .multilineTextAlignment(.center)
            Text(
                isOffline
                    ? "You\u{2019}re offline \u{2014} bookings will appear once you\u{2019}re back online."
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
                    Text("Retry")
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
}

private struct BookingRow: View {
    let item: ItineraryItem
    /// UX audit finding 3: true while this row's local write hasn't been
    /// confirmed by the server yet.
    let isPending: Bool

    /// UX audit finding 2: read so `card`/`a11yLabel` can protect the
    /// confirmation code — this tab's entire reason to exist — at
    /// accessibility Dynamic Type sizes, matching the isAccessibilitySize
    /// branching every other row already does (`TimelineCardRow`/
    /// `CheckOutRow`/`StayingStripRow`).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    private var isAXSize: Bool { dynamicTypeSize.isAccessibilitySize }

    var body: some View {
        NavigationLink(value: ItemRoute(id: item.id)) {
            Group {
                if isAXSize {
                    axCard
                } else {
                    card
                }
            }
            .padding(Spacing.md)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .overlay {
                // UX audit finding 3: same dashed-border treatment
                // `TimelineCardRow` uses, so a not-yet-synced booking looks
                // identical to how it looks on the Itinerary tab.
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .strokeBorder(
                        isPending ? Palette.slate.opacity(0.35) : Color.clear,
                        style: StrokeStyle(lineWidth: 1.25, dash: isPending ? [5, 4] : [])
                    )
            }
            // Finding 4: one spoken element per row — names the category
            // (conveyed only by the icon tile visually), the title, the
            // date, and the *full* confirmation code (even though the
            // visual truncates it in the middle), plus pending status. The
            // NavigationLink still supplies the button trait; `children:
            // .ignore` also silences the decorative chevron and the
            // `CategoryIconTile`'s own label.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
        }
        .buttonStyle(.plain)
    }

    private var titleAndDate: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title)
                .font(Typo.body(Typo.Size.body, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(isAXSize ? 2 : 1)
                .layoutPriority(1)
            Text(TimelineBuilder.dayTitleText(item.startLocalDay))
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
        }
    }

    private var card: some View {
        HStack(spacing: Spacing.md) {
            CategoryIconTile(category: item.category, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                titleAndDate
                if isPending { PendingSyncChip() }
            }
            Spacer(minLength: Spacing.sm)
            // Finding 5: a long pasted confirmation code would otherwise
            // wrap mid-code and crowd the title toward zero width — one
            // mono line, truncated in the middle (keeps the code's
            // distinguishing head/tail visible); the full code is one
            // tap away in `BookingDetailView`. Finding 2: `.layoutPriority(1)`
            // so the code shares space with the (also layoutPriority(1))
            // title instead of being starved to a sliver first.
            Text(item.confirmation ?? "")
                .font(Typo.mono(Typo.Size.caption))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.slate.opacity(0.6))
        }
    }

    /// Finding 2: at accessibility sizes, the confirmation code moves onto
    /// its own full-width line under the date, with no `.truncationMode`
    /// pre-truncation — a full line is available, so don't clip it.
    private var axCard: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            CategoryIconTile(category: item.category, side: 34)
            VStack(alignment: .leading, spacing: 2) {
                titleAndDate
                Text(item.confirmation ?? "")
                    .font(Typo.mono(Typo.Size.caption))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(2)
                if isPending { PendingSyncChip() }
            }
            Spacer(minLength: Spacing.sm)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Palette.slate.opacity(0.6))
        }
    }

    private var a11yLabel: String {
        var parts = [
            item.category.displayName,
            item.title,
            TimelineBuilder.dayTitleText(item.startLocalDay),
            "confirmation \(item.confirmation ?? "")",
        ]
        if isPending { parts.append("waiting to sync") }
        return parts.joined(separator: ", ")
    }
}
