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

    @State private var toast: String?
    @State private var isPresentingEdit = false
    @State private var isPresentingDeleteConfirm = false
    @State private var isEditingNotes = false
    @State private var notesDraft = ""
    /// Haptics (award-polish pass): flipped once `deleteItem` actually runs
    /// (i.e. the confirmation dialog's destructive button was tapped, not
    /// just opened), read only by the `.sensoryFeedback` in `body`.
    @State private var didDeleteItem = false

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
        .task {
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
    }

    private func headerIconBadge(_ systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.white.opacity(0.18))
            .frame(width: 40, height: 40)
            .overlay { Image(systemName: systemImage).foregroundStyle(.white) }
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
                Spacer()
                Text(flightName.isEmpty ? item.title : flightName)
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(.white)
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

    /// The perforated lower grid — two notch circles cut from the card's
    /// background plus a dashed rule, then a 2-column Passenger/Seat/
    /// Confirmation/Terminal·Gate (or category equivalent) grid.
    private func perforatedGrid(for item: ItineraryItem) -> some View {
        VStack(spacing: Spacing.lg) {
            dashedRule
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

    private var dashedRule: some View {
        Rectangle()
            .fill(Palette.mist)
            .frame(height: 1)
            .overlay {
                Rectangle()
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
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
                    // UX audit finding 6: object-specific toast ("Code
                    // copied"/"Ticket copied"), not a bare "Copied" — matches
                    // `ShareTripView`'s "Link copied" via the shared
                    // `ClipboardFeedback` helper.
                    toast = ClipboardFeedback.copy(value, label: label == "Confirmation" ? "Code" : "Ticket")
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
