import CoreLocation
import EventKit
import MapKit
import SwiftData
import SwiftUI
import UIKit

/// The boarding-pass style booking detail (BUILD_PLAN.md §4.4). Pushed via
/// the shared `ItemRoute` navigation destination (see `TripView.swift`'s
/// doc comment on the one route-based `NavigationStack` rooted in
/// `HomeView`) from both `ItineraryTabView`'s cards and `BookingsTabView`'s
/// rows — so it takes an `itemId` and queries for the row itself, the same
/// "receive an id, `@Query` the rest" shape `TripView` already uses for
/// `tripId`.
struct BookingDetailView: View {
    let itemId: UUID

    @Query private var items: [ItineraryItem]
    // Unfiltered, like `HomeView`'s own queries — RLS already scopes these
    // to what this account can see, and it's a handful of rows at most.
    @Query private var trips: [Trip]
    @Query private var members: [TripMember]
    @Query private var tripProfiles: [TripProfile]
    @Query private var profiles: [Profile]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss
    /// Findings 1/2/6: the `isAccessibilitySize` AX-branch convention used
    /// throughout Features/Trip (`TripCard.swift`, `TripView.tabBar()`).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// PLAN-signature-layer.md §D3: gates the scroll tilt/sheen off, and
    /// simplifies the tear-off drag to a linear translate with no rotation.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var toast: String?
    @State private var isPresentingEdit = false
    @State private var isPresentingDeleteConfirm = false
    @State private var isEditingNotes = false
    @State private var notesDraft = ""
    /// Haptics (award-polish pass): flipped once `deleteItem` actually runs
    /// (i.e. the confirmation dialog's destructive button was tapped, not
    /// just opened), read only by the `.sensoryFeedback` in `body`.
    @State private var didDeleteItem = false

    // MARK: Boarding-pass physicality state (PLAN-signature-layer.md §D3)

    /// `passCard`'s own minY in `PassEffects.scrollSpace`, written by
    /// `.measuringMinY` — drives the scroll tilt + header sheen.
    @State private var passCardMinY: CGFloat = 0

    /// Live drag translation (pt) while tearing the stub; 0 when idle or
    /// once torn (the detached constants take over rendering then).
    @State private var tearTranslation: CGFloat = 0
    /// Persisted "already torn today" state for the opened item, hydrated
    /// in `.onAppear` from `PassEffects.isTornStub`.
    @State private var isTornStub = false
    /// The torn stub's current resting tilt — starts at the detach's 8°
    /// "fling" and eases down to the 1° resting value shortly after.
    @State private var tornRestRotation = PassEffects.tearDetachRotationDegrees
    @State private var didCrossTearTick30 = false
    @State private var didCrossTearTick60 = false
    @State private var hasShownDiscoveryNudge = false
    @State private var discoveryNudgeOffset: CGFloat = 0

    /// Copy choreography's stamp (scale bump on the tapped value).
    @State private var isStampingCopyCell = false

    /// `.sensoryFeedback` triggers — toggled, never read, same convention
    /// as `didDeleteItem` above. Kept as plain `Bool`s rather than one
    /// shared trigger so two beats that could land in the same view update
    /// (e.g. a fast drag crossing both tick thresholds at once) each still
    /// fire independently.
    @State private var copyTouchTrigger = false
    @State private var copySuccessTrigger = false
    @State private var tearTick30Trigger = false
    @State private var tearTick60Trigger = false
    @State private var discoveryTickTrigger = false
    @State private var tearSettleTrigger = false

    /// Icon sizes next to this screen's own Sofia Sans caption/mono text —
    /// see the shared `@ScaledMetric` recipe used throughout Features/Trip.
    /// Not used inside `flightHeader`/`transportHeader`/etc. — those sit in
    /// the boarding-pass hero art with their own fixed decorative glyphs
    /// (route-line airplane, header badge icon), not an icon-beside-caption
    /// pairing this recipe is for.
    @ScaledMetric(relativeTo: .body) private var lockIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var copyIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .body) private var actionIconSize: CGFloat = 18

    init(itemId: UUID) {
        self.itemId = itemId
        _items = Query(filter: #Predicate<ItineraryItem> { $0.id == itemId })
    }

    private var item: ItineraryItem? { items.first }
    private var trip: Trip? {
        guard let item else { return nil }
        return trips.first { $0.id == item.tripId }
    }

    private var myRole: TripRole? {
        guard let item, let userId = authManager.userId else { return nil }
        return members.first { $0.tripId == item.tripId && $0.userId == userId }?.role
    }

    private var canEdit: Bool {
        guard let item else { return false }
        return ItemPermissions.canEdit(item: item, role: myRole, userId: authManager.userId)
    }

    var body: some View {
        Group {
            if let item, let trip {
                content(item: item, trip: trip)
            } else {
                missingItemState
            }
        }
        .background(Palette.paper)
        .navigationTitle("Booking details")
        .navigationBarTitleDisplayMode(.inline)
        .toastOverlay($toast)
        // Haptics (award-polish pass): warning on a confirmed delete — see
        // `didDeleteItem`.
        .sensoryFeedback(.warning, trigger: didDeleteItem)
        // Boarding-pass physicality haptics (PLAN-signature-layer.md §D3),
        // all attached here at this always-mounted level rather than inside
        // the conditionally-rendered stub branches — a trigger toggled in
        // the same update that also swaps branches (e.g. `tearSettleTrigger`
        // alongside `isTornStub` flipping true) must never land on a
        // modifier that's simultaneously leaving the hierarchy.
        .sensoryFeedback(Haptics.touch, trigger: copyTouchTrigger)
        .sensoryFeedback(Haptics.success, trigger: copySuccessTrigger)
        .sensoryFeedback(Haptics.tick, trigger: tearTick30Trigger)
        .sensoryFeedback(Haptics.tick, trigger: tearTick60Trigger)
        .sensoryFeedback(Haptics.tick, trigger: discoveryTickTrigger)
        .sensoryFeedback(Haptics.settle, trigger: tearSettleTrigger)
        .onAppear {
            // Synchronous (not `.task`) so an already-torn stub never
            // flashes as draggable for one frame before this hydrates.
            guard let item else { return }
            isTornStub = PassEffects.isTornStub(itemId: item.id, day: item.startLocalDay)
        }
        .task {
            if let item {
                var suppressDiscoveryNudge = false
                #if DEBUG
                suppressDiscoveryNudge = applyDebugTearEvidenceOverrides()
                #endif
                // Discovery: one small nudge + tick the first time this
                // view appears on a travel day, before the stub is torn.
                // `hasShownDiscoveryNudge` is plain view-local `@State`, not
                // persisted, so this re-arms on every fresh open of this
                // screen -- not a true once-per-calendar-day thing. What
                // actually stops it for good is the stub getting torn
                // (`isTornStub`, which IS persisted per day via
                // `PassEffects`). Skipped under RM (an unprompted
                // animation+buzz, not a user-driven one) and while an
                // evidence override is deterministically posing the stub
                // already.
                if isTravelDay(item), !isTornStub, !reduceMotion, !hasShownDiscoveryNudge, !suppressDiscoveryNudge {
                    hasShownDiscoveryNudge = true
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    withAnimation(Motion.snappy) { discoveryNudgeOffset = 4 }
                    discoveryTickTrigger.toggle()
                    try? await Task.sleep(nanoseconds: 140_000_000)
                    withAnimation(Motion.snappy) { discoveryNudgeOffset = 0 }
                }
            }
            #if DEBUG
            // M2 verify-drill autopilot only (see `WelcomeView`/`HomeView`/
            // `TripView`'s matching hooks) — exercises the real
            // EKEventStore path with no tap automation available here.
            if ProcessInfo.processInfo.arguments.contains("-uitestAddToCalendar"), let item {
                try? await Task.sleep(nanoseconds: 400_000_000)
                addToCalendar(item)
            }
            #endif
        }
    }

    // MARK: - Boarding-pass physicality helpers (PLAN-signature-layer.md §D3)

    /// "Device-local today == the item's start day in its own zone" — see
    /// `PassEffects.isTravelDay`'s doc comment for why only today's side
    /// needs computing here.
    private var effectiveToday: DayDate {
        #if DEBUG
        // See `applyDebugTearEvidenceOverrides`'s doc comment — evidence
        // capture only, never reachable outside an explicit launch arg.
        if ProcessInfo.processInfo.arguments.contains("-uitestForceTravelDay"), let item {
            return item.startLocalDay
        }
        #endif
        return DayDate.today(calendar: .current)
    }

    private func isTravelDay(_ item: ItineraryItem) -> Bool {
        PassEffects.isTravelDay(item: item, today: effectiveToday)
    }

    /// Off under RM and at accessibility sizes (the plan's tilt/sheen
    /// carve-out) — a 3D rotation and a sliding highlight are exactly the
    /// kind of motion those settings ask apps to drop, and the AX-branch
    /// flight header already reflows structurally at those sizes.
    private var tiltDegrees: Double {
        (reduceMotion || dynamicTypeSize.isAccessibilitySize) ? 0 : PassEffects.tiltDegrees(minY: passCardMinY)
    }

    private var sheenProgress: Double {
        (reduceMotion || dynamicTypeSize.isAccessibilitySize) ? 0 : PassEffects.scrollProgress(minY: passCardMinY)
    }

    private func tearDragGesture(for item: ItineraryItem) -> some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                tearTranslation = value.translation.width
                let progress = PassEffects.tearProgress(translation: tearTranslation)
                if progress >= PassEffects.tearTick30Progress, !didCrossTearTick30 {
                    didCrossTearTick30 = true
                    tearTick30Trigger.toggle()
                }
                if progress >= PassEffects.tearTick60Progress, !didCrossTearTick60 {
                    didCrossTearTick60 = true
                    tearTick60Trigger.toggle()
                }
            }
            .onEnded { value in
                didCrossTearTick30 = false
                didCrossTearTick60 = false
                if PassEffects.hasReachedDetachThreshold(translation: value.translation.width) {
                    detachStub(item: item)
                } else {
                    withAnimation(Motion.m(Motion.snappy, reduceMotion: reduceMotion)) {
                        tearTranslation = 0
                    }
                }
            }
    }

    /// Release ≥96pt, or the VoiceOver "Tear off stub" action directly:
    /// travels to the detached constants (`Motion.standard`, `Haptics.settle`
    /// as it lands), then eases its rotation down from the 8° fling to the
    /// 1° resting tilt (`Motion.gentle` — the vocabulary's own "settles"
    /// tier) and persists so it stays torn until the travel day passes.
    private func detachStub(item: ItineraryItem) {
        tornRestRotation = PassEffects.tearDetachRotationDegrees
        withAnimation(Motion.m(Motion.standard, reduceMotion: reduceMotion)) {
            isTornStub = true
            tearTranslation = 0
        }
        tearSettleTrigger.toggle()
        PassEffects.setTornStub(true, itemId: item.id, day: item.startLocalDay)
        Task {
            try? await Task.sleep(nanoseconds: 320_000_000)
            withAnimation(Motion.m(Motion.gentle, reduceMotion: reduceMotion)) {
                tornRestRotation = PassEffects.tearRestRotationDegrees
            }
        }
    }

    #if DEBUG
    /// W1-B evidence-capture scaffolding only (PLAN-signature-layer.md §D3's
    /// VERIFY step) — `DemoSeeder`'s seeded flight is hardcoded to May 2026
    /// and is outside this package's file set to change, so no seeded
    /// flight's real device-local "today" is ever its travel day. These
    /// flags drive the exact same `PassEffects`/state plumbing a real
    /// travel day + drag would, deterministically, for screenshots. Never
    /// present outside an explicit `-uitest…` launch argument; compiled out
    /// of Release, same convention as this file's other `-uitest…` hooks.
    /// - `-uitestForceTravelDay`: see `effectiveToday`.
    /// - `-uitestTearProgress <0-1>`: seeds `tearTranslation` to that
    ///   fraction of the detach threshold (a "mid-tear" screenshot).
    /// - `-uitestForceTornStub`: seeds the persisted torn/resting state
    ///   directly (a "post-tear" screenshot).
    /// Returns true while either of the latter two is active, so the
    /// discovery nudge (which would otherwise animate mid-screenshot) stays
    /// quiet.
    private func applyDebugTearEvidenceOverrides() -> Bool {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uitestForceTornStub") {
            isTornStub = true
            tornRestRotation = PassEffects.tearRestRotationDegrees
            return true
        }
        if let index = args.firstIndex(of: "-uitestTearProgress"), index + 1 < args.count,
            let fraction = Double(args[index + 1]) {
            tearTranslation = PassEffects.tearThreshold * CGFloat(fraction)
            return true
        }
        return false
    }
    #endif

    private func content(item: ItineraryItem, trip: Trip) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                passCard(for: item)
                tagsBlock(for: item)
                editedByLabel(for: item)
                actionRow(for: item)
                notesBlock(for: item)

                if !canEdit {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: lockIconSize))
                            // Decorative — the adjacent sentence already
                            // says this item is read-only.
                            .accessibilityHidden(true)
                        Text("Only the person who added this, or an organizer, can change it.")
                    }
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                    .padding(.top, Spacing.xs)
                }
            }
            .padding(Spacing.xl)
        }
        // Boarding-pass scroll tilt (PLAN-signature-layer.md §D3) measures
        // `passCard`'s position against this named space via
        // `.measuringMinY` — see `tiltDegrees`/`sheenProgress`.
        .coordinateSpace(.named(PassEffects.scrollSpace))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if canEdit {
                    Button {
                        isPresentingEdit = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    Button(role: .destructive) {
                        isPresentingDeleteConfirm = true
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
        }
        .sheet(isPresented: $isPresentingEdit) {
            AddItemSheet(tripId: trip.id, tripTitle: trip.title, editing: item) { message in
                toast = message
            }
        }
        .confirmationDialog(
            "Delete this item?", isPresented: $isPresentingDeleteConfirm, titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { deleteItem(item) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes \u{201C}\(item.title)\u{201D} from the itinerary for everyone on the trip.")
        }
    }

    // MARK: - Pass card (BUILD_PLAN.md §4.4, §6.3 "the boarding-pass detail card")

    private func passCard(for item: ItineraryItem) -> some View {
        VStack(spacing: 0) {
            // Finding 1: this used to cap the whole boarding-pass hero art
            // at `.accessibility2` as an interim guard against the flight
            // header's fixed-width route-line/IATA-pair layout, which had
            // nowhere to reflow. `flightHeader` now branches to its own
            // vertical layout at accessibility sizes instead (see its doc
            // comment) — the other three header variants (hotel/simple/
            // transport) were never the problem (no fixed side-by-side
            // pairing), so no cap is needed here anymore and every variant
            // scales all the way to accessibility5, matching the grid below.
            passHeader(for: item)
            perforatedGrid(for: item)
        }
        .background(Palette.elevated)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Palette.shadow.opacity(0.18), radius: 20, y: 12)
        // Scroll-based tilt (PLAN-signature-layer.md §D3) — deliberately
        // scroll position, not CoreMotion: no permission/battery cost,
        // deterministic in screenshots/tests, trivially off under RM/AX via
        // `tiltDegrees`. No shadow pumping, no scale — physical, not
        // gimmicky, per §6.5.
        .measuringMinY(in: PassEffects.scrollSpace, into: $passCardMinY)
        .rotation3DEffect(.degrees(tiltDegrees), axis: (x: 1, y: 0, z: 0))
    }

    @ViewBuilder
    private func passHeader(for item: ItineraryItem) -> some View {
        switch item.category {
        case .flight: flightHeader(for: item)
        case .hotel: hotelHeader(for: item)
        case .activity, .food: simpleHeader(for: item)
        case .transport: transportHeader(for: item)
        }
    }

    /// Category gradient plus a topLeading-heavy black scrim (BUILD_PLAN.md
    /// §7.3 "overlay scrims"). Every header gradient runs topLeading →
    /// bottomTrailing with the header text living in the upper-left band —
    /// the scrim is heaviest there and fades toward bottomTrailing so it
    /// lifts contrast exactly where the text sits without flattening the
    /// signature look. Shared by all three gradient headers (flight,
    /// transport, hotel) so the fix — and any future tuning — stays in one
    /// place; `simpleHeader` (activity/food) uses a light background and
    /// doesn't need this.
    private func gradientHeaderFill(_ color: Color) -> some View {
        LinearGradient(colors: [color, Palette.indigo], startPoint: .topLeading, endPoint: .bottomTrailing)
            .overlay(
                LinearGradient(
                    colors: [.black.opacity(0.45), .black.opacity(0.10)], startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            // Specular sheen (PLAN-signature-layer.md §D3), gradient
            // headers only: a faint diagonal highlight whose origin slides
            // with the same scroll progress driving `passCard`'s tilt —
            // pinned to its rest position (no slide) under RM/AX via
            // `sheenProgress`.
            .overlay(
                LinearGradient(
                    colors: [.white.opacity(0.08), .white.opacity(0)],
                    startPoint: PassEffects.sheenStart(progress: sheenProgress),
                    endPoint: .bottomTrailing
                )
                .allowsHitTesting(false)
            )
    }

    private func headerIconBadge(_ systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.18))
            .frame(width: 40, height: 40)
            .overlay { Image(systemName: systemImage).foregroundStyle(.white) }
    }

    /// PLAN-signature-layer.md §D3's "glass" pill — real frosted material
    /// (not another flat white-opacity fill like `headerIconBadge`) so it
    /// reads as a distinct, quiet status badge against the gradient.
    private var travelDayPill: some View {
        Text("Travel day")
            .font(Typo.body(11, weight: .bold))
            .tracking(0.3)
            .foregroundStyle(.white)
            .padding(.horizontal, Spacing.sm)
            .padding(.vertical, 5)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay { Capsule().stroke(.white.opacity(0.35), lineWidth: 1) }
    }

    private func flightHeader(for item: ItineraryItem) -> some View {
        let details = item.details
        let flightName = [details.airline, details.flightNo].compactMap { $0 }.joined(separator: " ")
        let depTime = ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)
        let depZone = ItineraryTimeZone.zoneLabel(for: item.primaryTz, at: item.startsAt)
        // Bug fix: was `citySegment(of: item.primaryTz.identifier)` — the
        // timezone's canonical city, not the actual airport's city (EWR's
        // zone is "America/New_York", so this showed "New York" for a
        // Newark departure). Falls back to the old timezone-derived city
        // for an airport `AirportTimeZones` doesn't know, same graceful
        // degradation `tzIdentifier` already uses elsewhere in this file.
        let depCity = details.fromIATA.flatMap(AirportTimeZones.cityName(for:))
            ?? ItineraryTimeZone.citySegment(of: item.primaryTz.identifier)
        let arrivalTz = item.effectiveTz
        let endsAt = item.endsAt ?? item.startsAt
        let arrTime = ItineraryTimeZone.timeString(endsAt, in: arrivalTz)
        let arrZone = ItineraryTimeZone.zoneLabel(for: arrivalTz, at: endsAt)
        let arrCity = details.toIATA.flatMap(AirportTimeZones.cityName(for:))
            ?? ItineraryTimeZone.citySegment(of: arrivalTz.identifier)

        return VStack(alignment: .leading, spacing: Spacing.xl) {
            HStack {
                headerIconBadge("airplane")
                // PLAN-signature-layer.md §D3: "a quiet 'Travel day' glass
                // pill" — the same trigger that makes the stub below
                // drag-interactive. Inline next to the fixed-size badge only
                // at default sizes (verified AX5: the pill's capsule grows
                // tall enough at 2 wrapped lines to crowd the 40pt badge in
                // a shared row) — moved to its own full-width row below at
                // accessibility sizes instead, same "give up on sharing a
                // row, go vertical" call as the from/to layout right below.
                if isTravelDay(item), !dynamicTypeSize.isAccessibilitySize {
                    travelDayPill
                }
                Spacer()
                Text(flightName.isEmpty ? item.title : flightName)
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(.white)
            }
            if isTravelDay(item), dynamicTypeSize.isAccessibilitySize {
                travelDayPill
            }
            // Finding 1: the side-by-side IATA/route-line layout below has
            // two fixed-width columns either side of a fixed-width
            // `routeLine` with no room to reflow — at accessibility sizes
            // this switches to a single leading-aligned column instead
            // (departure, then arrival), the same "give up on side-by-side,
            // go vertical" shape `transportHeader` already uses for its
            // pickup/drop-off pair below. `.lineLimit(2)` relief on the
            // city/time captions now that each has a full-width line to
            // wrap into, instead of the cramped column it had before.
            // Default rendering in the `else` branch is untouched.
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: Spacing.lg) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.fromIATA ?? "—")
                            .font(Typo.display(34))
                        Text("\(depCity) · \(depTime) \(depZone)")
                            .font(Typo.body(Typo.Size.caption))
                            .lineLimit(2)
                    }
                    Image(systemName: "airplane")
                        .font(.system(size: 15))
                        .foregroundStyle(.white.opacity(0.7))
                        .rotationEffect(.degrees(135))
                        // Decorative connector between the two endpoint
                        // blocks — the from/to codes and cities either side
                        // already say "flight," same reasoning as
                        // `routeLine` below.
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.toIATA ?? "—")
                            .font(Typo.display(34))
                        Text("\(arrCity) · \(arrTime) \(arrZone)")
                            .font(Typo.body(Typo.Size.caption))
                            .lineLimit(2)
                    }
                }
                .foregroundStyle(.white)
            } else {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(details.fromIATA ?? "—")
                            .font(Typo.display(34))
                        Text("\(depCity) · \(depTime) \(depZone)")
                            .font(Typo.body(Typo.Size.caption))
                    }
                    Spacer(minLength: Spacing.sm)
                    routeLine
                    Spacer(minLength: Spacing.sm)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(details.toIATA ?? "—")
                            .font(Typo.display(34))
                        Text("\(arrCity) · \(arrTime) \(arrZone)")
                            .font(Typo.body(Typo.Size.caption))
                    }
                }
                .foregroundStyle(.white)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(gradientHeaderFill(CategoryColor.flight.fg))
    }

    private var routeLine: some View {
        // Boarding-pass hero art, not a labeled glyph next to text — this
        // connecting rule between the two IATA codes stays a fixed size.
        // Only rendered at non-accessibility sizes now: finding 1's
        // vertical branch replaces the whole side-by-side layout —
        // `routeLine` included — once `dynamicTypeSize.isAccessibilitySize`
        // is true (see `flightHeader`), so it never needs to grow.
        // Decorative: the from/to codes and cities either side already say
        // "flight."
        ZStack {
            Rectangle().fill(.white.opacity(0.4)).frame(height: 1)
            Image(systemName: "airplane")
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .rotationEffect(.degrees(90))
                .padding(.horizontal, Spacing.xs)
                .background(CategoryColor.flight.fg)
        }
        .frame(width: 46)
        .padding(.top, 10)
        .accessibilityHidden(true)
    }

    /// Transport uses a *vertical* pickup → drop-off layout (not the flight's
    /// side-by-side IATA pair) because locations are free text ("Boston Logan"),
    /// not 3-letter codes — the flight layout would overflow.
    private func transportHeader(for item: ItineraryItem) -> some View {
        let details = item.details
        let depTime = ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)
        let depZone = ItineraryTimeZone.zoneLabel(for: item.primaryTz, at: item.startsAt)
        let dropTz = item.effectiveTz
        let endsAt = item.endsAt ?? item.startsAt
        let arrTime = ItineraryTimeZone.timeString(endsAt, in: dropTz)
        let arrZone = ItineraryTimeZone.zoneLabel(for: dropTz, at: endsAt)
        let depDate = Self.shortDate(item.startsAt, in: item.primaryTz)
        let arrDate = Self.shortDate(endsAt, in: dropTz)
        let pickup = item.locationName.isEmpty ? "Pickup" : item.locationName
        let dropoff = details.dropoffLocation ?? "Drop-off"

        return VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack {
                headerIconBadge("car.fill")
                Spacer()
                Text(details.provider ?? item.title)
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: Spacing.sm) {
                transportEndpoint(label: "Pickup", place: pickup, time: "\(depDate) \u{00B7} \(depTime) \(depZone)")
                transportEndpoint(label: "Drop-off", place: dropoff, time: "\(arrDate) \u{00B7} \(arrTime) \(arrZone)")
            }
            .foregroundStyle(.white)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(gradientHeaderFill(CategoryColor.transport.fg))
    }

    /// Short localized "Mon 14"-style date for a boarding-pass endpoint, in the
    /// endpoint's own zone — a multi-day rental's dates are exactly what you
    /// open the pass to confirm (persona dry-run).
    static func shortDate(_ instant: Date, in tz: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = tz
        formatter.setLocalizedDateFormatFromTemplate("EEEMMMd")
        return formatter.string(from: instant)
    }

    private func transportEndpoint(label: String, place: String, time: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label.uppercased())
                .font(Typo.body(9, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                // `minWidth` (not a fixed `width`) — "PICKUP"/"DROP-OFF"
                // keeps its column alignment at default size but can still
                // grow to fit instead of clipping as Dynamic Type scales up
                // (finding 1 removed the header's old `.accessibility2`
                // cap; this row already reflows fine uncapped since neither
                // this label nor `place`'s own 2-line cap forces a fixed
                // width).
                .frame(minWidth: 64, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(place).font(Typo.display(20)).lineLimit(2)
                Text(time).font(Typo.body(Typo.Size.caption))
            }
        }
    }

    private func hotelHeader(for item: ItineraryItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                headerIconBadge("bed.double.fill")
                Spacer()
            }
            Text(item.title)
                .font(Typo.display(26))
                .foregroundStyle(.white)
            if !item.locationName.isEmpty {
                Text(item.locationName)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(.white)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(gradientHeaderFill(CategoryColor.hotel.fg))
    }

    private func simpleHeader(for item: ItineraryItem) -> some View {
        HStack(spacing: Spacing.md) {
            CategoryIconTile(category: item.category, side: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(Typo.display(22))
                    .foregroundStyle(Palette.ink)
                if !item.locationName.isEmpty {
                    Text(item.locationName)
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Palette.elevated)
    }

    /// The perforated lower grid — "the stub" (PLAN-signature-layer.md §D3):
    /// two notch circles cut from the card's background plus a dashed rule,
    /// then a 2-column Passenger/Seat/Confirmation/Terminal·Gate (or
    /// category equivalent) grid. On a flight's travel day it also becomes
    /// drag-interactive (`travelDayStub`); every other category/day renders
    /// `stubContent` exactly as before — zero visual change beyond the tilt,
    /// per §6.5.
    @ViewBuilder
    private func perforatedGrid(for item: ItineraryItem) -> some View {
        if isTravelDay(item) {
            travelDayStub(for: item)
        } else {
            stubContent(for: item, dashProgress: 0)
        }
    }

    private func stubContent(for item: ItineraryItem, dashProgress: Double) -> some View {
        VStack(spacing: Spacing.lg) {
            dashedRule(progress: dashProgress)
            LazyVGrid(
                columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                spacing: Spacing.lg
            ) {
                ForEach(gridCells(for: item), id: \.0) { cell in
                    gridCell(label: cell.0, value: cell.1)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xl)
        }
        .background(Palette.elevated)
        .overlay(alignment: .top) {
            HStack {
                Circle().fill(Palette.paper).frame(width: 22, height: 22).offset(x: -11, y: -11)
                Spacer()
                Circle().fill(Palette.paper).frame(width: 22, height: 22).offset(x: 11, y: -11)
            }
        }
    }

    /// Flight, travel day only. Two branches: already-torn renders the
    /// fixed resting state with no gesture (nothing left to tear); not
    /// -yet-torn tracks the live drag and exposes the VoiceOver-equivalent
    /// action — "a drag-only interaction is an AX fail."
    @ViewBuilder
    private func travelDayStub(for item: ItineraryItem) -> some View {
        if isTornStub {
            stubContent(for: item, dashProgress: 1)
                .rotationEffect(.degrees(reduceMotion ? 0 : tornRestRotation), anchor: .topLeading)
                .offset(x: PassEffects.tearDetachOffsetX, y: PassEffects.tearDetachOffsetY)
                // "Stub carries its own soft shadow" once resting, reading
                // as a loose stub laid back on the pass.
                .shadow(color: Palette.shadow.opacity(0.22), radius: 10, y: 6)
        } else {
            stubContent(for: item, dashProgress: PassEffects.tearProgress(translation: tearTranslation))
                .rotationEffect(
                    .degrees(reduceMotion ? 0 : PassEffects.tearRotationDegrees(translation: tearTranslation)),
                    anchor: .topLeading
                )
                .offset(x: PassEffects.tearOffsetX(translation: tearTranslation) + discoveryNudgeOffset, y: 0)
                .contentShape(Rectangle())
                // `.simultaneousGesture`, not `.gesture`: the stub sits
                // inside a vertical `ScrollView` — this lets a scroll
                // started on the stub keep scrolling normally (this
                // gesture's `translation.width` stays ~0 for a vertical
                // drag) instead of the two gesture recognizers fighting
                // over the same touch.
                .simultaneousGesture(tearDragGesture(for: item))
                .accessibilityAction(named: "Tear off stub") { detachStub(item: item) }
        }
    }

    private func dashedRule(progress: Double) -> some View {
        Rectangle()
            .fill(Palette.mist)
            .frame(height: 1)
            .overlay {
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, PassEffects.dashGapWidth(progress: progress)]))
                    .foregroundStyle(Palette.mist)
            }
            .padding(.top, Spacing.md)
    }

    private func gridCell(label: String, value: String) -> some View {
        let isCopyable = (label == "Confirmation" || label == "Ticket") && value != "—"
        return VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Typo.body(11, weight: .bold))
                .foregroundStyle(Palette.slate)
                .tracking(0.4)
            if isCopyable {
                Button {
                    performCopy(label: label, value: value)
                } label: {
                    HStack(spacing: 4) {
                        Text(value)
                            .font(Typo.mono(15.5))
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: copyIconSize))
                            // Decorative — the mono value text next to it
                            // and the hint below already say what this does.
                            .accessibilityHidden(true)
                    }
                    // Copy choreography's "stamp" beat (PLAN-signature-layer.md
                    // §D3) — see `performCopy`.
                    .scaleEffect(isStampingCopyCell ? 1.06 : 1)
                    // D2 defect 7: `Palette.indigo` is a fixed fill color
                    // (same hex both themes, Tokens.swift) — fine for the
                    // assignee-tile fill it's designed for, but low-contrast
                    // as dark-on-dark-elevated text in dark mode. `.ink`
                    // matches the mono-code treatment `BookingsTabView`'s
                    // `BookingRow`/`axCard` already use for confirmation
                    // codes and adapts light/dark like the rest of this
                    // card's text.
                    .foregroundStyle(Palette.ink)
                    // Finding 7 (§6.5 44pt floor): grows only the invisible
                    // tappable band around the ~20pt-tall label — same
                    // recipe as `AddItemFormSections.nextDayChip`/
                    // `TripView.pasteImportPill`, visuals unchanged.
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Double tap to copy")
            } else {
                Text(value)
                    .font(Typo.body(15.5, weight: .semibold))
                    .foregroundStyle(Palette.ink)
            }
        }
        // Groups the label + value into one VoiceOver stop ("Passenger,
        // Naveen Kumar") instead of two unrelated swipes. Skipped for the
        // copy-button branch (`.contain`, the default) — folding an
        // interactive Button into a `.combine`d element would cost it its
        // own tap target and hint.
        .accessibilityElement(children: isCopyable ? .contain : .combine)
    }

    /// Haptic-choreographed copy (PLAN-signature-layer.md §D3): two distinct
    /// beats instead of one flat tap-and-toast. Beat 1 (immediate):
    /// `Haptics.touch` plus the "stamp" scale bump (`isStampingCopyCell`,
    /// applied in `gridCell`) on the tapped value. Beat 2 (~0.25s later,
    /// once the stamp has settled back down): the existing
    /// `ClipboardFeedback` toast, with its success haptic fired here instead
    /// (`haptic: false` below) so the two beats read as one choreographed
    /// gesture rather than a doubled buzz.
    private func performCopy(label: String, value: String) {
        copyTouchTrigger.toggle()
        withAnimation(Motion.m(Motion.snappy, reduceMotion: reduceMotion)) {
            isStampingCopyCell = true
        }
        Task {
            try? await Task.sleep(nanoseconds: 120_000_000)
            withAnimation(Motion.m(Motion.snappy, reduceMotion: reduceMotion)) {
                isStampingCopyCell = false
            }
            try? await Task.sleep(nanoseconds: 130_000_000)
            // UX audit finding 6: object-specific toast ("Code copied"/
            // "Ticket copied"), not a bare "Copied" — matches
            // `ShareTripView`'s "Link copied" via the shared
            // `ClipboardFeedback` helper.
            toast = ClipboardFeedback.copy(value, label: label == "Confirmation" ? "Code" : "Ticket", haptic: false)
            copySuccessTrigger.toggle()
        }
    }

    /// One 4-cell grid per category (this milestone's brief: flight =
    /// Passenger/Seat/Confirmation/Terminal·Gate; hotel = Guest/Nights/
    /// Confirmation/Check-in; activity/food = "simpler frame, same grid").
    /// "Passenger"/"Guest" has no real assignee model yet (v1.5+'s
    /// `ItemAssignee` per BUILD_PLAN.md §3.3) — the best available v1 proxy
    /// is whoever added the booking.
    private func gridCells(for item: ItineraryItem) -> [(String, String)] {
        let details = item.details
        switch item.category {
        case .flight:
            return [
                ("Passenger", displayName(for: item.createdBy)),
                ("Seat", details.seat ?? "—"),
                ("Confirmation", item.confirmation ?? "—"),
                ("Terminal · Gate", terminalGateText(details)),
            ]
        case .hotel:
            return [
                ("Guest", displayName(for: item.createdBy)),
                ("Nights", item.stayNightCount > 0 ? "\(item.stayNightCount)" : "—"),
                ("Confirmation", item.confirmation ?? "—"),
                ("Check-in", ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)),
            ]
        case .activity:
            return [
                ("Date", TimelineBuilder.dayTitleText(item.startLocalDay)),
                ("Time", timeAndZoneText(item)),
                ("Ticket", item.confirmation ?? "—"),
                ("Address", details.address ?? (item.locationName.isEmpty ? "—" : item.locationName)),
            ]
        case .food:
            return [
                ("Date", TimelineBuilder.dayTitleText(item.startLocalDay)),
                ("Time", timeAndZoneText(item)),
                ("Party size", details.partySize.map(String.init) ?? "—"),
                ("Reservation", details.reservationName ?? "—"),
            ]
        case .transport:
            return [
                ("Provider", details.provider ?? "—"),
                ("Confirmation", item.confirmation ?? "—"),
                ("Pickup", ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)),
                ("Drop-off", ItineraryTimeZone.timeString(item.endsAt ?? item.startsAt, in: item.effectiveTz)),
            ]
        }
    }

    private func terminalGateText(_ details: ItemDetails) -> String {
        let parts = [details.terminal, details.gate].compactMap { $0 }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    private func timeAndZoneText(_ item: ItineraryItem) -> String {
        let time = ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)
        let zone = ItineraryTimeZone.zoneLabel(for: item.primaryTz, at: item.startsAt)
        return "\(time) \(zone)"
    }

    /// updated_by → name lookup mirroring `TripView.profileNames` (checks
    /// account profiles, then trip profiles linked to that account).
    private func displayName(for userId: UUID) -> String {
        guard let tripId = item?.tripId else { return "Traveler" }
        if let profile = profiles.first(where: { $0.id == userId }) {
            return profile.displayName
        }
        if let tripProfile = tripProfiles.first(where: { $0.tripId == tripId && $0.linkedUserId == userId }) {
            return tripProfile.displayName
        }
        return "Traveler"
    }

    /// The kid-aware tags dropped when this screen was cut over from the
    /// timeline (finding 3) — same `WrapLayout`/`TagChip` pair
    /// `TimelineCardRow` uses (`TimelineRowViews.swift`), so a tag reads
    /// identically whether you're scanning the timeline or the detail card.
    @ViewBuilder
    private func tagsBlock(for item: ItineraryItem) -> some View {
        if !item.details.tags.isEmpty {
            WrapLayout(horizontalSpacing: Spacing.xs, verticalSpacing: Spacing.xs) {
                ForEach(item.details.tags, id: \.self) { tag in
                    TagChip(tag: tag)
                }
            }
        }
    }

    /// updated_by → name lookup mirroring `TripView.profileNames` (checks
    /// account profiles, then trip profiles linked to that account).
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

    /// "edited by {name} · {relative time}" (finding 4) — dropped when this
    /// screen was cut over from the timeline; reuses the same pure
    /// `TimelineBuilder.editedByText` the timeline card renders so the two
    /// surfaces never disagree.
    @ViewBuilder
    private func editedByLabel(for item: ItineraryItem) -> some View {
        if let text = TimelineBuilder.editedByText(
            for: item, myUserId: authManager.userId, namesById: profileNames, now: .now
        ) {
            Text(text)
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
        }
    }

    // MARK: - Action row (BUILD_PLAN.md §4.4: "Add to calendar · Get directions · Share with group")

    /// Finding 6: 3-tile row at default size; stacks vertically at
    /// accessibility sizes so each label gets the sheet's full width to
    /// wrap into instead of a cramped 1/3 column — same `AnyLayout` swap
    /// pattern as `TripCard`'s `topLayout`/`metaLayout`.
    private var actionRowLayout: AnyLayout {
        dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: Spacing.sm))
            : AnyLayout(HStackLayout(spacing: Spacing.md))
    }

    private func actionRow(for item: ItineraryItem) -> some View {
        actionRowLayout {
            Button {
                addToCalendar(item)
            } label: {
                // Finding 6: a literal "\n" mid-label forced an exact
                // 2-line break that couldn't reflow once Dynamic Type grew
                // past what the old fixed `lineLimit(2)` column could show.
                // A plain sentence lets `Text` wrap on its own based on the
                // space it actually has (~1/3 of the row by default, the
                // full row at accessibility sizes via `actionRowLayout`).
                actionLabel(icon: "calendar.badge.plus", text: "Add to calendar")
            }
            .buttonStyle(.plain)

            Button {
                getDirections(item)
            } label: {
                actionLabel(icon: "location.fill", text: "Get directions")
            }
            .buttonStyle(.plain)

            ShareLink(item: ShareSummary.text(for: item)) {
                actionLabel(icon: "square.and.arrow.up", text: "Share with group")
            }
        }
    }

    private func actionLabel(icon: String, text: String) -> some View {
        VStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(.system(size: actionIconSize))
                .foregroundStyle(Palette.indigo)
                // Decorative — the label below already names the action;
                // each of these three is a Button/ShareLink whose label
                // already reads as one VoiceOver stop.
                .accessibilityHidden(true)
            Text(text)
                .font(Typo.body(11, weight: .semibold))
                .foregroundStyle(Palette.slate)
                .multilineTextAlignment(.center)
                // Finding 6: was a hard `2` matching the old literal "\n"
                // break — relaxed at accessibility sizes so a label that
                // needs a 3rd line isn't truncated instead of just
                // wrapping; default stays capped at 2 as before.
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.md)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous).stroke(Palette.mist, lineWidth: 1)
        }
    }

    /// EventKit is the one place this screen leaves pure SwiftUI — the
    /// draft itself comes from `CalendarEventDraft`/`CalendarEventBuilder`
    /// (Foundation-only, unit tested with no EventKit involved).
    private func addToCalendar(_ item: ItineraryItem) {
        let draft = CalendarEventBuilder.draft(for: item)
        let store = EKEventStore()
        Task {
            do {
                let granted = try await store.requestWriteOnlyAccessToEvents()
                guard granted else {
                    toast = "Calendar access is off. Turn it on in Settings > Tripto to add events."
                    return
                }
                let event = EKEvent(eventStore: store)
                event.title = draft.title
                event.startDate = draft.startDate
                event.endDate = draft.endDate
                event.timeZone = draft.timeZone
                event.location = draft.locationName
                event.notes = draft.notes
                event.calendar = store.defaultCalendarForNewEvents
                try store.save(event, span: .thisEvent)
                toast = "Added to Calendar"
            } catch {
                toast = "Couldn\u{2019}t save to Calendar. Try again in a moment."
            }
        }
    }

    /// `MKMapItem` from lat/lng when known, else best-effort `CLGeocoder`
    /// resolution of the free-text `location_name` (this milestone's
    /// brief) — v1 has no obligation to always resolve a location.
    ///
    /// Flights are special-cased to the *arrival* airport rather than the
    /// booking's own `location_name`/lat-lng (which, for a flight, is the
    /// departure) — directions matter most in the "landed, disoriented"
    /// moment, not before boarding. Falls back to the departure airport if
    /// no arrival code is on the booking.
    private func getDirections(_ item: ItineraryItem) {
        Task {
            var coordinate: CLLocationCoordinate2D?
            if item.category == .flight {
                let details = item.details
                if let iata = details.toIATA ?? details.fromIATA, !iata.isEmpty {
                    let geocoder = CLGeocoder()
                    coordinate = try? await geocoder.geocodeAddressString("\(iata) airport").first?.location?.coordinate
                }
            } else if let lat = item.locationLat, let lng = item.locationLng {
                coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lng)
            } else if !item.locationName.isEmpty {
                let geocoder = CLGeocoder()
                coordinate = try? await geocoder.geocodeAddressString(item.locationName).first?.location?.coordinate
            }
            guard let coordinate else {
                toast = item.category == .flight
                    ? "Couldn\u{2019}t find that airport. Check the airport code on this flight."
                    : "Add an address to this item to get directions."
                return
            }
            let placemark = MKPlacemark(coordinate: coordinate)
            let mapItem = MKMapItem(placemark: placemark)
            if item.category == .flight {
                let details = item.details
                mapItem.name = details.toIATA ?? details.fromIATA ?? item.title
            } else {
                mapItem.name = item.locationName.isEmpty ? item.title : item.locationName
            }
            mapItem.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDefault])
        }
    }

    // MARK: - Notes (BUILD_PLAN.md §4.4: "a trip note block for free text")

    private func notesBlock(for item: ItineraryItem) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack {
                Text("TRIP NOTE")
                    .font(Typo.body(12, weight: .bold))
                    .foregroundStyle(Palette.slate)
                    .tracking(0.5)
                Spacer()
                if canEdit, !isEditingNotes {
                    Button("Edit") {
                        notesDraft = item.notes ?? ""
                        isEditingNotes = true
                    }
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    // Finding 3: raw `Palette.amber` as foreground text
                    // measures ~2.3:1 on `Palette.elevated` (fails AA) —
                    // `amberInk` is the same darkened, AA-compliant amber
                    // the codebase already uses for inline text actions.
                    .foregroundStyle(Palette.amberInk)
                }
            }

            if isEditingNotes {
                TextEditor(text: $notesDraft)
                    .frame(minHeight: 90)
                    .font(Typo.body())
                    .padding(Spacing.xs)
                    .background(Palette.paper, in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous).stroke(Palette.mist, lineWidth: 1)
                    }
                HStack {
                    Spacer()
                    Button("Cancel") { isEditingNotes = false }
                        .foregroundStyle(Palette.slate)
                    Button("Save") { saveNotes(item) }
                        // Finding 3: same `amberInk` swap as "Edit" above.
                        .foregroundStyle(Palette.amberInk)
                }
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
            } else {
                let notes = item.notes ?? ""
                let emptyStateText = canEdit
                    ? "Add a note for the group \u{2014} a gate change, a packing reminder, anything."
                    : "No note yet. An organizer can add one."
                Text(notes.isEmpty ? emptyStateText : notes)
                    .font(Typo.body())
                    .foregroundStyle(notes.isEmpty ? Palette.slate : Palette.ink)
            }
        }
        .padding(Spacing.lg)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous).stroke(Palette.mist, lineWidth: 1)
        }
    }

    private func saveNotes(_ item: ItineraryItem) {
        item.notes = notesDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : notesDraft
        item.updatedAt = .now
        item.updatedBy = authManager.userId
        try? modelContext.save()
        let dto = item.toDTO()
        let rowId = item.id
        let tripId = item.tripId
        Task { await syncEngine?.enqueueUpsert(table: .itineraryItems, rowId: rowId, tripId: tripId, payload: dto) }
        isEditingNotes = false
        toast = "Note saved"
    }

    // MARK: - Delete (role-gated, confirm dialog — this milestone's brief)

    private func deleteItem(_ item: ItineraryItem) {
        let rowId = item.id
        let tripId = item.tripId
        modelContext.delete(item)
        try? modelContext.save()
        Task { await syncEngine?.enqueueDelete(table: .itineraryItems, rowId: rowId, tripId: tripId) }
        didDeleteItem.toggle()
        dismiss()
    }

    /// Finding 4: parity with `TripView.missingTripState` — explains the
    /// likely cause instead of a bare headline, marks the headline
    /// `.isHeader`, and swaps the bare-amber-text "Back" for the same
    /// filled `Palette.amber`/`Palette.onAmber` capsule CTA (finding 3's
    /// established pattern, `TripView.swift`'s own `missingTripState`).
    private var missingItemState: some View {
        VStack(spacing: Spacing.md) {
            Text("This item is no longer available")
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(
                "It may have been removed by an organizer or companion, or your access " +
                    "to this trip may have ended."
            )
            .font(Typo.body())
            .foregroundStyle(Palette.slate)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.xxl)
            Button(action: { dismiss() }) {
                Text("Back")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
