import SwiftData
import SwiftUI

/// Contextual add/edit sheet (BUILD_PLAN.md §4.3; this milestone's brief).
/// One category selector drives four very different field sets — kept as
/// plain per-category `@State` rather than one generic form model, matching
/// `SyncStore`'s own "eight plain methods are easier to read and debug than
/// one clever generic one" philosophy at this scale.
///
/// Presented twice: `TripView`'s FAB (`editing: nil`) and
/// `BookingDetailView`'s "Edit" action (`editing: <item>`) — both go through
/// this one sheet so add and edit share every field/validation/zone-default
/// rule. Every save is the same "SwiftData write on the main context, then
/// `SyncEngine.enqueue`" flow `TripFormView` already established.
struct AddItemSheet: View {
    let tripId: UUID
    let tripTitle: String
    let editing: ItineraryItem?
    let onToast: (String) -> Void
    /// The zone a *new* item's pickers should default to — the trip's dominant
    /// existing-item zone (see `NewItemZoneDefault`), so a Lisbon trip doesn't
    /// offer the traveler's home clock. `.current` when adding to an empty trip
    /// or when editing (edit reads zones off the item instead).
    let defaultZone: TimeZone
    /// Finding 1 (companion fix, same bug class as `PackingListView`'s
    /// `tripCreatedBy`): the id to stamp a *new* item's `createdBy` with
    /// when adding while signed out — the signed-out user IS the local
    /// trip creator (see `TripView.canAddItems`'s doc comment), so this is
    /// their own uid from when they created the trip; the later push will
    /// satisfy RLS once they sign back in. `nil` for edit-mode call sites
    /// (`BookingDetailView`) that never need it — `save()`'s create branch
    /// is the only place this is read.
    var tripCreatedBy: UUID?

    @Query var tripProfiles: [TripProfile]
    @Query private var members: [TripMember]
    /// `ItemAssignee`s for the item being edited — filtered to a sentinel
    /// (never-matching) id when adding, since there's no item yet to have
    /// any. Seeds `selectedAssigneeProfileIds` once via `.task` below
    /// (`@Query` results aren't available synchronously in `init`, unlike
    /// `editing`'s other fields).
    @Query private var existingAssignees: [ItemAssignee]

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(SyncStatus.self) private var syncStatus
    @Environment(\.dismiss) private var dismiss
    /// P7c: gates the `importAddressCard` teaser's expand/collapse animation
    /// (`Design/Motion.swift`'s policy — off under Reduce Motion).
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Finding 2: `categorySelector`'s AX-size horizontal-scroll branch,
    /// same `isAccessibilitySize` convention as `TripView.tabBar()`. Not
    /// `private` (Phase 3) — `AddItemFormSections.flightSection`'s live
    /// preview reads it too, so the embedded `BoardingPassCard` restacks at
    /// the same accessibility sizes as everything else in the sheet.
    @Environment(\.dynamicTypeSize) var dynamicTypeSize

    @State var category: ItemCategory

    // Family (M4 §3): "Who's this for?" + kid-aware tags — apply across
    // every category, unlike the fields above.
    @State var selectedTags: Set<String> = []
    @State var selectedAssigneeProfileIds: Set<UUID> = []
    @State private var originalAssigneeProfileIds: Set<UUID> = []
    @State private var hasLoadedAssignees = false

    // Flight
    @State var airline = ""
    @State var flightNo = ""
    @State var fromIATA = ""
    @State var toIATA = ""
    @State var flightDate = Date()
    @State var departsTime = Date()
    @State var departureZone: TimeZone = .current
    @State var arrivalDate = Date()
    /// P7c (award audit #4): `nil` until the user actually sets a real
    /// arrival — a blank new flight (or an edited item whose own `endsAt`
    /// was never known) has nothing real yet to compute a duration/day
    /// badge from, so `flightFields()`/`flightPreviewModel` read `nil` as
    /// "route-only," the same nil-`Endpoint.date` state `BoardingPassCard`
    /// already renders for a flight with no known arrival (P1). The Arrives
    /// picker still needs *some* concrete value to display before that
    /// first real edit — `arrivesTimeBinding` (`AddItemFormSections.swift`)
    /// supplies a departure-relative placeholder that's never read as data,
    /// replacing the old wall-clock-derived `Date()+2h` default the live
    /// preview used to assert as if it were real (the actual bug: two
    /// screenshots of the same JFK->LIS route landed different fabricated
    /// durations purely because they were captured a few minutes apart).
    @State var arrivesTime: Date?
    @State var arrivalZone: TimeZone = .current
    @State var seat = ""
    @State var terminal = ""
    @State var gate = ""
    /// Phase 3 (P3.3): the seat/terminal/gate/confirmation `DisclosureGroup`'s
    /// own expand state (`AddItemFormSections.flightSection`) — seeded once
    /// in `init` below (collapsed on a blank form, expanded if editing an
    /// item that already has any of the four filled in), a plain toggle
    /// from then on. Not `private` — that file's extension binds to it.
    @State var isFlightDetailsExpanded = false

    // Stay
    @State var stayName = ""
    @State var checkInDate = Date()
    @State var checkInTime = Date()
    @State var checkOutDate = Date()
    @State var checkOutTime = Date()
    @State var stayZone: TimeZone = .current
    @State var room = ""

    // Activity
    @State var activityTitle = ""
    @State var activityDate = Date()
    @State var activityTime = Date()
    @State var activityZone: TimeZone = .current
    @State var ticketRef = ""

    // Food
    @State var foodName = ""
    @State var foodDate = Date()
    @State var foodTime = Date()
    @State var foodZone: TimeZone = .current
    @State var partySize = ""
    @State var reservationName = ""

    // Transport (rental car / train / ferry / transfer) — pickup A → drop-off B,
    // structurally a flight. Pickup location reuses the shared `locationText`;
    // `dropoffText` is the drop-off place; `dropoffDate`/`dropoffTime` are its
    // own explicit pickers (no day-offset toggle) — the same shape flight's
    // `arrivalDate`/`arrivesTime` now use too (P7c).
    @State var transportTitle = ""
    @State var provider = ""
    @State var transportDate = Date()
    @State var pickupTime = Date()
    @State var pickupZone: TimeZone = .current
    @State var dropoffText = ""
    @State var dropoffDate = Date()
    @State var dropoffTime = Date()
    @State var dropoffZone: TimeZone = .current
    /// Off by default: a same-city rental drops off in the pickup zone, so the
    /// form shows one zone, not two (persona dry-run). On reveals a separate
    /// drop-off zone picker for a zone-crossing train/ferry.
    @State var transportDropoffDiffZone = false

    // Shared across non-flight categories
    @State var confirmation = ""
    @State var locationText = ""
    @State var locationLat: Double?
    @State var locationLng: Double?
    @State var address: String?

    /// Finding 2 (companion fix): mirrors `TripFormView`'s `SaveError` — a
    /// failed `modelContext.save()` used to be swallowed by `try?`, so the
    /// sheet dismissed and toasted success even though nothing was actually
    /// persisted. Single-case (unlike `TripFormView`'s `.signedOut` variant)
    /// since this sheet has no equivalent unrecoverable state; every write
    /// failure here is presumed transient/retryable.
    private enum SaveError: Equatable {
        case writeFailed
        var message: String { "Couldn\u{2019}t save this item. Try again." }
    }
    @State private var saveError: SaveError?

    /// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): the "Dismiss" action's live
    /// `dismiss_email_import_item` RPC call is in flight — disables both
    /// CTAs so a second tap can't fire a duplicate request or race the save
    /// path, and backs the inline error message below on failure.
    @State private var isDismissingSuggestion = false
    @State private var dismissError: String?

    /// Fix-round D2: `save()` has no `await` (a fully synchronous SwiftData
    /// insert + `dismiss()`), so a fast double-tap can land a second Button
    /// action before either SwiftUI re-renders the `.disabled` footer or the
    /// dismiss animation removes it — confirmed live to insert two
    /// `ItineraryItem`s from one double-tap. Same guard shape as
    /// `isDismissingSuggestion` above: set synchronously as `save()`'s first
    /// statement (so a second, still-synchronous call sees it immediately,
    /// no render pass required) and gates both footer Save buttons'
    /// `.disabled`.
    @State private var isSaving = false

    /// Phase 3 (P3.5): `pasteFirstBanner`'s own sub-sheet — opens the exact
    /// same `PasteImportSheet` every other entry point uses, untouched.
    @State private var isPresentingPasteImport = false
    /// Phase 4 (P4.2, docs/UX_REDESIGN_ROADMAP.md): the email-import address
    /// card, relocated here from `ShareTripView` — "getting data in" (paste
    /// OR forward-by-email) is one cluster now, next to `pasteFirstBanner`,
    /// not split across screens. Same `LoadState`/consent shape every other
    /// call site (`ItineraryTabView.importTeaser`, which stays put) already
    /// uses — see `importAddressCard`'s doc comment.
    @State private var importLoadState: ImportAddressCard.LoadState = EmailImportConsent.isGranted() ? .loading : .needsConsent
    @State private var hasFetchedImportAddress = false
    /// P7c (award audit #7): collapsed by default — see `importAddressCard`'s
    /// own doc comment for why.
    @State private var isImportCardExpanded = false
    /// Finding 3: gates the "Discard changes?" confirmation on cancel/swipe-
    /// dismiss, same as `TripFormView`.
    @State private var showDiscardConfirm = false
    /// Haptics (award-polish pass): flipped once `save()` actually lands
    /// (add or edit), read only by the `.sensoryFeedback` in `body` — fires
    /// on the save landing, not on the Save button tap itself.
    @State private var didSave = false

    /// `categoryTile`'s icon, stacked above its own label — see the shared
    /// `@ScaledMetric` recipe used throughout Features/Trip.
    @ScaledMetric(relativeTo: .body) private var categoryIconSize: CGFloat = 18
    /// `tagToggle`'s icon (`AddItemFormSections.swift`) — not `private` so
    /// that file's `extension AddItemSheet` can read it; Swift extensions
    /// can't declare their own stored properties.
    @ScaledMetric(relativeTo: .body) var tagIconSize: CGFloat = 10
    /// `pasteFirstBanner`'s trailing chevron — same recipe as `ZonePicker`'s.
    @ScaledMetric(relativeTo: .caption) private var pasteBannerChevronSize: CGFloat = 12
    /// `footerBar`'s "Save & add the return leg" icon, next to its own
    /// label — same shared `@ScaledMetric` recipe.
    @ScaledMetric(relativeTo: .body) private var returnLegIconSize: CGFloat = 14

    private static let lastDepartureTZKey = "lastDepartureTZ"
    private static func lastArrivalTZKey(_ tripId: UUID) -> String { "lastArrivalTZ.\(tripId.uuidString)" }

    /// Finding 3: every editable per-category `@State` field plus the shared
    /// confirmation/location fields and family tags — captured once as
    /// `initialSnapshot` at the end of `init` (after either branch has set
    /// every field) so `hasChanges` can tell an untouched form from a dirty
    /// one, exactly like `TripFormView.InitialValues`. Assignees are tracked
    /// separately via `originalAssigneeProfileIds` (seeded later, from
    /// `.task`) rather than folded in here.
    private struct EditSnapshot: Equatable {
        var category: ItemCategory
        var selectedTags: Set<String>

        var airline: String
        var flightNo: String
        var fromIATA: String
        var toIATA: String
        var flightDate: Date
        var departsTime: Date
        var departureZone: TimeZone
        var arrivalDate: Date
        var arrivesTime: Date?
        var arrivalZone: TimeZone
        var seat: String
        var terminal: String
        var gate: String

        var stayName: String
        var checkInDate: Date
        var checkInTime: Date
        var checkOutDate: Date
        var checkOutTime: Date
        var stayZone: TimeZone
        var room: String

        var activityTitle: String
        var activityDate: Date
        var activityTime: Date
        var activityZone: TimeZone
        var ticketRef: String

        var foodName: String
        var foodDate: Date
        var foodTime: Date
        var foodZone: TimeZone
        var partySize: String
        var reservationName: String

        var transportTitle: String
        var provider: String
        var transportDate: Date
        var pickupTime: Date
        var pickupZone: TimeZone
        var dropoffText: String
        var dropoffDate: Date
        var dropoffTime: Date
        var dropoffZone: TimeZone
        var transportDropoffDiffZone: Bool

        var confirmation: String
        var locationText: String
        var locationLat: Double?
        var locationLng: Double?
        var address: String?
    }
    private let initialSnapshot: EditSnapshot

    init(
        tripId: UUID, tripTitle: String, editing: ItineraryItem?, defaultZone: TimeZone = .current,
        tripStartDate: Date = .now, tripCreatedBy: UUID? = nil,
        onToast: @escaping (String) -> Void
    ) {
        self.tripId = tripId
        self.tripTitle = tripTitle
        self.editing = editing
        self.onToast = onToast
        self.defaultZone = defaultZone
        self.tripCreatedBy = tripCreatedBy

        _tripProfiles = Query(filter: #Predicate<TripProfile> { $0.tripId == tripId })
        _members = Query(filter: #Predicate<TripMember> { $0.tripId == tripId })
        let existingAssigneesItemId = editing?.id ?? UUID()
        _existingAssignees = Query(filter: #Predicate<ItemAssignee> { $0.itemId == existingAssigneesItemId })

        if let editing {
            let details = editing.details
            _category = State(initialValue: editing.category)
            _confirmation = State(initialValue: editing.confirmation ?? "")
            _locationText = State(initialValue: editing.locationName)
            _locationLat = State(initialValue: editing.locationLat)
            _locationLng = State(initialValue: editing.locationLng)
            _address = State(initialValue: details.address)
            _selectedTags = State(initialValue: Set(details.tags))

            switch editing.category {
            case .flight:
                _airline = State(initialValue: details.airline ?? "")
                _flightNo = State(initialValue: details.flightNo ?? "")
                _fromIATA = State(initialValue: details.fromIATA ?? "")
                _toIATA = State(initialValue: details.toIATA ?? "")
                _flightDate = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                _departsTime = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                _departureZone = State(initialValue: editing.primaryTz)
                let arrivalTz = details.arrivalTz.flatMap(TimeZone.init(identifier:)) ?? editing.primaryTz
                _arrivalZone = State(initialValue: arrivalTz)
                // P7c: an `endsAt` that was never known (an import/
                // suggestion gap) seeds both pickers at the departure's own
                // day/time as a neutral starting point, exactly like a
                // blank new item below — `arrivesTime` stays `nil`
                // (`hasSetArrival` false) until whoever's editing supplies
                // a real one, rather than quietly treating that seed as data.
                let endsAt = editing.endsAt ?? editing.startsAt
                let arrivalPickerDate = Self.pickerDate(from: endsAt, in: arrivalTz)
                _arrivalDate = State(initialValue: arrivalPickerDate)
                _arrivesTime = State(initialValue: editing.endsAt == nil ? nil : arrivalPickerDate)
                _seat = State(initialValue: details.seat ?? "")
                _terminal = State(initialValue: details.terminal ?? "")
                _gate = State(initialValue: details.gate ?? "")
            case .hotel:
                _stayName = State(initialValue: editing.title)
                _checkInDate = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                _checkInTime = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                let endsAt = editing.endsAt ?? editing.startsAt
                _checkOutDate = State(initialValue: Self.pickerDate(from: endsAt, in: editing.primaryTz))
                _checkOutTime = State(initialValue: Self.pickerDate(from: endsAt, in: editing.primaryTz))
                _stayZone = State(initialValue: editing.primaryTz)
                _room = State(initialValue: details.room ?? "")
            case .activity:
                _activityTitle = State(initialValue: editing.title)
                _activityDate = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                _activityTime = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                _activityZone = State(initialValue: editing.primaryTz)
                _ticketRef = State(initialValue: details.ticketRef ?? "")
            case .food:
                _foodName = State(initialValue: editing.title)
                _foodDate = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                _foodTime = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                _foodZone = State(initialValue: editing.primaryTz)
                _partySize = State(initialValue: details.partySize.map(String.init) ?? "")
                _reservationName = State(initialValue: details.reservationName ?? "")
            case .transport:
                _transportTitle = State(initialValue: editing.title)
                _provider = State(initialValue: details.provider ?? "")
                _transportDate = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                _pickupTime = State(initialValue: Self.pickerDate(from: editing.startsAt, in: editing.primaryTz))
                _pickupZone = State(initialValue: editing.primaryTz)
                _dropoffText = State(initialValue: details.dropoffLocation ?? "")
                let dropTz = details.arrivalTz.flatMap(TimeZone.init(identifier:)) ?? editing.primaryTz
                _dropoffZone = State(initialValue: dropTz)
                _transportDropoffDiffZone = State(initialValue: dropTz.identifier != editing.primaryTz.identifier)
                let endsAt = editing.endsAt ?? editing.startsAt
                _dropoffDate = State(initialValue: Self.pickerDate(from: endsAt, in: dropTz))
                _dropoffTime = State(initialValue: Self.pickerDate(from: endsAt, in: dropTz))
            }
        } else {
            _category = State(initialValue: .flight)
            let lastDeparture = UserDefaults.standard.string(forKey: Self.lastDepartureTZKey)
                .flatMap(TimeZone.init(identifier:))
            let lastArrival = UserDefaults.standard.string(forKey: Self.lastArrivalTZKey(tripId))
                .flatMap(TimeZone.init(identifier:))
            // New items default to the trip's own zone rather than the device
            // clock ("Hong Kong time on a Lisbon trip"). A flight keeps any
            // remembered per-trip zones, and arrival no longer silently mirrors
            // departure — it too starts from the trip zone until an airport code
            // resolves it.
            let departureDefault = lastDeparture ?? defaultZone
            _departureZone = State(initialValue: departureDefault)
            _arrivalZone = State(initialValue: lastArrival ?? defaultZone)
            _stayZone = State(initialValue: defaultZone)
            _activityZone = State(initialValue: defaultZone)
            _foodZone = State(initialValue: defaultZone)
            _pickupZone = State(initialValue: defaultZone)
            _dropoffZone = State(initialValue: defaultZone)
            // Lean new-item dates toward the trip's start (a May trip shouldn't
            // default every item to today) — arrival's date leans the same
            // way, same day as departure until the user says otherwise
            // (persona dry-run). P7c: arrival's *time* stays unset (`nil`)
            // rather than a clock-derived guess — see `arrivesTime`'s own
            // doc comment.
            let dateDefault = tripStartDate > Date() ? tripStartDate : Date()
            _flightDate = State(initialValue: dateDefault)
            _arrivalDate = State(initialValue: dateDefault)
            _activityDate = State(initialValue: dateDefault)
            _foodDate = State(initialValue: dateDefault)
            _transportDate = State(initialValue: dateDefault)
            _dropoffDate = State(initialValue: dateDefault)
            _checkInDate = State(initialValue: dateDefault)
            _checkInTime = State(initialValue: Self.timeOfDay(hour: 15, minute: 0))
            _checkOutTime = State(initialValue: Self.timeOfDay(hour: 11, minute: 0))
            _checkOutDate = State(initialValue: Calendar.current.date(byAdding: .day, value: 1, to: dateDefault) ?? dateDefault)
        }

        // Phase 3 (P3.3): collapsed by default on a blank form; expanded
        // from the start when editing an item that already has any of the
        // four filled in, so opening "Edit flight" never hides data the
        // item actually has. Reads the just-set `_seat`/`_terminal`/`_gate`/
        // `_confirmation` wrapped values (same legal-inside-`init` trick
        // `initialSnapshot` below uses) since either branch above has
        // already populated them by this point.
        let hasFlightDetails = [_seat.wrappedValue, _terminal.wrappedValue, _gate.wrappedValue, _confirmation.wrappedValue]
            .contains { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        _isFlightDetailsExpanded = State(initialValue: hasFlightDetails)

        // Captured last, after either branch above has set every field —
        // reading the underscored `@State` wrappers' `wrappedValue` here
        // (rather than the plain properties) is what makes this legal inside
        // `init`, same as `TripFormView.initialValues`.
        initialSnapshot = EditSnapshot(
            category: _category.wrappedValue, selectedTags: _selectedTags.wrappedValue,
            airline: _airline.wrappedValue, flightNo: _flightNo.wrappedValue,
            fromIATA: _fromIATA.wrappedValue, toIATA: _toIATA.wrappedValue,
            flightDate: _flightDate.wrappedValue, departsTime: _departsTime.wrappedValue,
            departureZone: _departureZone.wrappedValue, arrivalDate: _arrivalDate.wrappedValue,
            arrivesTime: _arrivesTime.wrappedValue, arrivalZone: _arrivalZone.wrappedValue,
            seat: _seat.wrappedValue, terminal: _terminal.wrappedValue, gate: _gate.wrappedValue,
            stayName: _stayName.wrappedValue, checkInDate: _checkInDate.wrappedValue,
            checkInTime: _checkInTime.wrappedValue, checkOutDate: _checkOutDate.wrappedValue,
            checkOutTime: _checkOutTime.wrappedValue, stayZone: _stayZone.wrappedValue, room: _room.wrappedValue,
            activityTitle: _activityTitle.wrappedValue, activityDate: _activityDate.wrappedValue,
            activityTime: _activityTime.wrappedValue, activityZone: _activityZone.wrappedValue,
            ticketRef: _ticketRef.wrappedValue,
            foodName: _foodName.wrappedValue, foodDate: _foodDate.wrappedValue, foodTime: _foodTime.wrappedValue,
            foodZone: _foodZone.wrappedValue, partySize: _partySize.wrappedValue,
            reservationName: _reservationName.wrappedValue,
            transportTitle: _transportTitle.wrappedValue, provider: _provider.wrappedValue,
            transportDate: _transportDate.wrappedValue, pickupTime: _pickupTime.wrappedValue,
            pickupZone: _pickupZone.wrappedValue, dropoffText: _dropoffText.wrappedValue,
            dropoffDate: _dropoffDate.wrappedValue, dropoffTime: _dropoffTime.wrappedValue,
            dropoffZone: _dropoffZone.wrappedValue, transportDropoffDiffZone: _transportDropoffDiffZone.wrappedValue,
            confirmation: _confirmation.wrappedValue, locationText: _locationText.wrappedValue,
            locationLat: _locationLat.wrappedValue, locationLng: _locationLng.wrappedValue,
            address: _address.wrappedValue
        )
    }

    private var isEditing: Bool { editing != nil }

    /// EI-2: true while reviewing an unconfirmed email-import suggestion —
    /// swaps the primary CTA to "Confirm booking" and reveals the secondary
    /// "Dismiss" action. Reads `editing.status` live (not a value captured
    /// at `init`) so the CTA/action correctly disappear the instant `save()`
    /// flips the status to `.confirmed`, right before this sheet dismisses.
    private var isReviewingSuggestion: Bool { editing?.status == .suggested }

    /// EI-4: gates `unverifiedSenderCallout` — `editing` is guaranteed
    /// non-nil whenever `isReviewingSuggestion` is true, but the two
    /// properties don't share that guarantee at the type level, so this
    /// still reads `editing` via `?`, not a force-unwrap.
    private var isReviewingUnverifiedSuggestion: Bool {
        isReviewingSuggestion && editing?.isFromUnverifiedSender == true
    }

    /// P3.6: "Save & add the return leg" is add-mode only — `editing` is an
    /// immutable `let`, so the only way a second `save()` call from THIS
    /// sheet is guaranteed to create a new item (never re-save over the
    /// flight just added) is if `editing` was `nil` the whole time. Also
    /// hidden while reviewing a suggestion, whose primary CTA is "Confirm
    /// booking", not "Save" — there's no "leg on screen" to have just saved.
    private var showsReturnLegAction: Bool {
        category == .flight && !isEditing && !isReviewingSuggestion
    }

    /// Finding 3: the live counterpart to `initialSnapshot` — diffed against
    /// it (plus the separately-tracked assignee set) by `hasChanges`.
    private var currentSnapshot: EditSnapshot {
        EditSnapshot(
            category: category, selectedTags: selectedTags,
            airline: airline, flightNo: flightNo, fromIATA: fromIATA, toIATA: toIATA,
            flightDate: flightDate, departsTime: departsTime, departureZone: departureZone,
            arrivalDate: arrivalDate, arrivesTime: arrivesTime, arrivalZone: arrivalZone,
            seat: seat, terminal: terminal, gate: gate,
            stayName: stayName, checkInDate: checkInDate, checkInTime: checkInTime,
            checkOutDate: checkOutDate, checkOutTime: checkOutTime, stayZone: stayZone, room: room,
            activityTitle: activityTitle, activityDate: activityDate, activityTime: activityTime,
            activityZone: activityZone, ticketRef: ticketRef,
            foodName: foodName, foodDate: foodDate, foodTime: foodTime, foodZone: foodZone,
            partySize: partySize, reservationName: reservationName,
            transportTitle: transportTitle, provider: provider, transportDate: transportDate,
            pickupTime: pickupTime, pickupZone: pickupZone, dropoffText: dropoffText,
            dropoffDate: dropoffDate, dropoffTime: dropoffTime, dropoffZone: dropoffZone,
            transportDropoffDiffZone: transportDropoffDiffZone,
            confirmation: confirmation, locationText: locationText, locationLat: locationLat,
            locationLng: locationLng, address: address
        )
    }

    /// Finding 3: whether any field has moved from what the sheet opened
    /// with — gates Cancel/swipe-dismiss's "Discard changes?" prompt, same
    /// as `TripFormView.hasChanges`. Assignees are compared separately since
    /// they're seeded asynchronously (`.task`), not captured in `init`.
    private var hasChanges: Bool {
        currentSnapshot != initialSnapshot || selectedAssigneeProfileIds != originalAssigneeProfileIds
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
                SheetHeader(
                    title: isEditing ? "Edit \(category.displayName.lowercased())" : "Add to \(tripTitle)",
                    onCancel: cancelTapped
                )
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        if isReviewingUnverifiedSuggestion {
                            unverifiedSenderCallout
                        }

                        // Phase 3 (P3.5)/Phase 4 (P4.2): paste-first, then
                        // the email-import card, then the type rail — all
                        // add-mode only (an edit already has its own
                        // booking's data; re-pasting/re-importing would
                        // create a second, unrelated item, not fill this one
                        // in). Paste + forward-by-email is one "get data in"
                        // cluster now (P4.2 moved the card here from
                        // `ShareTripView` — getting data in \u{2260} getting
                        // people in).
                        if !isEditing {
                            pasteFirstBanner
                            importAddressCard
                            categorySelector
                        }

                        Group {
                            switch category {
                            case .flight: flightSection
                            case .hotel: staySection
                            case .activity: activitySection
                            case .food: foodSection
                            case .transport: transportSection
                            }
                        }

                        familySection
                    }
                    .padding(Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
                // Phase 3 (P3.6): sticky — a fixed sibling below the
                // `ScrollView`, not that view's last scrollable item any
                // more, so Save (and the return-leg action) stay reachable
                // without scrolling.
                footerBar
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { seedAssigneesIfNeeded() }
        // P4.2: `myRole` (below) is `@Query`-derived and can still be empty
        // on first render (mirrors `ShareTripView`'s identical `.task(id:
        // myRole)` — see that view's matching doc comment for why a plain
        // one-shot `.task` isn't enough here).
        .task(id: myRole) { await fetchImportAddressIfNeeded() }
        .onAppear {
            #if DEBUG
            // Verify-drill autopilot: preselect the Transport category so the
            // drop-off-date form can be screenshotted without GUI tap automation.
            if editing == nil, ProcessInfo.processInfo.arguments.contains("-uitestAddTransport") {
                category = .transport
            }
            #endif
        }
        // Phase 3 (P3.5): `pasteFirstBanner`'s door into the existing paste-
        // import flow — wired identically to `TripView.pasteImportPill`'s
        // own `.sheet` (same callbacks, same packing-item insert loop) so
        // this new entry point behaves exactly like every other one.
        .sheet(isPresented: $isPresentingPasteImport) {
            PasteImportSheet(
                tripId: tripId,
                onItineraryItemsImported: { created in
                    onToast("\(created) item\(created == 1 ? "" : "s") added to review")
                },
                onPackingConfirmed: { candidates in
                    guard let creatorId = authManager.userId ?? tripCreatedBy else { return }
                    for candidate in candidates {
                        PackingItem.insert(
                            label: candidate.label, groupKey: candidate.groupKey, assigneeProfileId: nil,
                            tripId: tripId, createdBy: creatorId,
                            modelContext: modelContext, syncEngine: syncEngine
                        )
                    }
                    onToast("\(candidates.count) item\(candidates.count == 1 ? "" : "s") added to packing list")
                },
                tripCreatedBy: tripCreatedBy
            )
        }
        .background(
            // Finding 3: surfaces the same "Discard changes?" dialog Cancel
            // uses when a dirty form's swipe-down is blocked by
            // `.interactiveDismissDisabled` below, mirroring `TripFormView`.
            SheetDismissAttemptObserver {
                if hasChanges {
                    showDiscardConfirm = true
                } else {
                    dismiss()
                }
            }
        )
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        // Haptics (award-polish pass): success on a landed save — see `didSave`.
        .sensoryFeedback(.success, trigger: didSave)
    }

    /// Finding 2: 5 equal-width tiles truncate their labels at accessibility
    /// sizes — same `isAccessibilitySize` horizontal-scroll branch as
    /// `TripView.tabBar()`/`PersonFilterBar`, so each tile keeps its full
    /// label instead of clipping. Non-AX rendering below is untouched.
    private var categorySelector: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(ItemCategory.allCases, id: \.self) { cat in
                            categoryTile(cat)
                        }
                    }
                }
            } else {
                HStack(spacing: Spacing.sm) {
                    ForEach(ItemCategory.allCases, id: \.self) { cat in
                        categoryTile(cat)
                    }
                }
            }
        }
    }

    private func categoryTile(_ cat: ItemCategory) -> some View {
        let isOn = category == cat
        return Button {
            category = cat
        } label: {
            VStack(spacing: Spacing.xs) {
                Image(systemName: cat.symbolName)
                    .font(.system(size: categoryIconSize, weight: .medium))
                    // Decorative — the label right below already names the category.
                    .accessibilityHidden(true)
                // Phase 3 (P3.1): verbs ("what am I adding"), not
                // `displayName`'s nouns — see `addSheetVerbLabel`'s doc
                // comment for why that property stays untouched.
                Text(cat.addSheetVerbLabel)
                    .font(Typo.body(11.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? cat.colorPair.fg : Palette.slate)
            // Finding 2: at accessibility sizes the row scrolls
            // horizontally instead of forcing 5 equal-width columns (see
            // `categorySelector`), so each tile sizes to its own label
            // (plus a little breathing room) instead of fighting for a
            // fifth of the sheet's width. Default rendering unchanged.
            .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? nil : .infinity)
            .padding(.horizontal, dynamicTypeSize.isAccessibilitySize ? Spacing.lg : 0)
            .padding(.vertical, Spacing.sm + 2)
            .background(isOn ? cat.colorPair.soft : Palette.elevated, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isOn ? cat.colorPair.fg : Palette.mist, lineWidth: 1.5)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
        // ponytail: XCUITest hook — the icon+text pairing can concatenate SF
        // Symbol accessibility text into the default label, so a plain
        // identifier is more reliable than matching on visible text here.
        .accessibilityIdentifier("addItemCategoryTile-\(cat.rawValue)")
    }

    /// EI-4: shown above the form only while reviewing a suggestion whose
    /// forwarder isn't a trip member (`isReviewingUnverifiedSuggestion`) —
    /// amber/caution, the same "heads up, not an error" treatment as
    /// `ImportReviewBanner` rather than `SyncIssueBanner`'s rose one: a
    /// prompt to double-check before confirming, not a failure.
    private var unverifiedSenderCallout: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                // Decorative — `.combine` below folds this row into one
                // VoiceOver stop that reads just the sentence.
                .accessibilityHidden(true)
            Text("Forwarded by someone who isn\u{2019}t on this trip \u{2014} double-check before confirming.")
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
        }
        .foregroundStyle(Palette.amberInk)
        .padding(Spacing.md)
        .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    /// Phase 3 (P3.5): the fast path — the data's already in the booking
    /// email, typing it twice is the actual pain. Opens the exact same
    /// `PasteImportSheet` every other entry point uses
    /// (`TripView.pasteImportPill`/`ShareTripView.pasteImportSecondaryAction`)
    /// — untouched, this is just one more door into it (see `body`'s
    /// `.sheet` for the wiring). Manual fields below stay the fallback, not
    /// the default path.
    private var pasteFirstBanner: some View {
        Button {
            isPresentingPasteImport = true
        } label: {
            HStack(spacing: Spacing.md) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Palette.amberSoft)
                    .frame(width: 40, height: 40)
                    .overlay {
                        // Same icon `TripView.pasteImportPill` uses — one
                        // consistent paste-import visual across every door.
                        Image(systemName: "doc.text.magnifyingglass")
                            .foregroundStyle(Palette.amberInk)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Paste a booking email")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(Palette.ink)
                    Text("Fills every field below in one tap")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(Palette.slate)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.sm)
                Image(systemName: "chevron.right")
                    .font(.system(size: pasteBannerChevronSize, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                    .accessibilityHidden(true)
            }
            .padding(Spacing.md)
            .frame(minHeight: 44)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .stroke(Palette.mist, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        // `.combine` concatenates the title/subtitle `Text`s into one
        // label, so matching by (partial) visible text is unreliable here —
        // same reasoning `categoryTile`'s own `accessibilityIdentifier`
        // doc comment already gives. `TriptoUITests
        // .testPasteImportEntryPointFromAddSheet` is the one reader.
        .accessibilityIdentifier("pasteFirstBanner")
    }

    /// Phase 4 (P4.2, docs/UX_REDESIGN_ROADMAP.md): the email-import address
    /// card, moved here from `ShareTripView` — getting data in (paste or
    /// forward-by-email) is this sheet's job now, not the people-and-links
    /// Share screen's (`ItineraryTabView`'s own copy stays put, unaffected).
    /// Same consent gating as before. Gated on `ItemPermissions.canAdd`,
    /// same reasoning as `ShareTripView.importCard` had:
    /// `get_or_create_trip_import_address` requires trip membership, so
    /// fetching for a viewer/signed-out visitor would just fail/spin behind
    /// a sheet they can't normally reach anyway.
    ///
    /// P7c (award audit #7): `ImportAddressCard` is a deliberately big, high-
    /// contrast navy hero at its OTHER two call sites (`ItineraryTabView`'s
    /// empty-state teaser, `ShareTripView`'s persistent card) — both screens
    /// where it's the main event. Inlined at that same size here, it
    /// out-weighed the whole manual form beneath it. Collapsed by default
    /// behind a teaser styled exactly like `pasteFirstBanner` right above it
    /// (same visual tier as the other "get data in" door, not a second
    /// hero), expanding in place to the untouched card on tap — this
    /// restyles the entry point's own collapsed weight only; the shared
    /// three-call-site `ImportAddressCard` component and its AI-disclosure/
    /// consent copy are unchanged, and every state (loading/loaded/failed)
    /// still renders exactly as before once expanded.
    @ViewBuilder
    private var importAddressCard: some View {
        if ItemPermissions.canAdd(role: myRole) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Button {
                    withAnimation(Motion.m(Motion.snappy, reduceMotion: reduceMotion)) {
                        isImportCardExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: Spacing.md) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Palette.amberSoft)
                            .frame(width: 40, height: 40)
                            .overlay {
                                // Same icon `ImportAddressCard` itself uses —
                                // one consistent email-import visual whether
                                // collapsed or expanded.
                                Image(systemName: "envelope.badge")
                                    .foregroundStyle(Palette.amberInk)
                            }
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Forward a booking email")
                                .font(Typo.body(weight: .semibold))
                                .foregroundStyle(Palette.ink)
                            Text("We\u{2019}ll add it to your itinerary for you to review")
                                .font(Typo.body(Typo.Size.caption))
                                .foregroundStyle(Palette.slate)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: Spacing.sm)
                        Image(systemName: isImportCardExpanded ? "chevron.up" : "chevron.right")
                            .font(.system(size: pasteBannerChevronSize, weight: .semibold))
                            .foregroundStyle(Palette.slate)
                            .accessibilityHidden(true)
                    }
                    .padding(Spacing.md)
                    .frame(minHeight: 44)
                    .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                            .stroke(Palette.mist, lineWidth: 1)
                    }
                    .contentShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint(isImportCardExpanded ? "Double tap to collapse" : "Double tap to expand")
                .accessibilityIdentifier("importAddressCardTeaser")

                if isImportCardExpanded {
                    ImportAddressCard(state: importLoadState) { address in
                        onToast(ClipboardFeedback.copy(address, label: "Import address"))
                    } onRetry: {
                        retryImportAddressFetch()
                    } onConsentGranted: {
                        grantEmailImportConsentAndFetch()
                    }
                }
            }
        }
    }

    /// Same one-shot-per-visit shape as `ShareTripView.fetchImportAddressIfNeeded()`
    /// (identical reasoning: `myRole` is `@Query`-derived and can still be
    /// empty on first render, so `.task(id: myRole)` above re-invokes this on
    /// every change rather than firing once; `hasFetchedImportAddress` is
    /// only ever set `true` once a fetch has actually been attempted).
    private func fetchImportAddressIfNeeded() async {
        guard ItemPermissions.canAdd(role: myRole), !hasFetchedImportAddress else { return }
        guard EmailImportConsent.fetchDecision() == .fetchImmediately else { return }
        hasFetchedImportAddress = true
        await fetchImportAddress()
    }

    /// The actual RPC call, split out so `retryImportAddressFetch()` can
    /// re-run it without re-triggering `hasFetchedImportAddress`'s guard.
    private func fetchImportAddress() async {
        do {
            importLoadState = .loaded(try await TripImportAddress.fetch(tripId: tripId))
        } catch {
            importLoadState = .failed
        }
    }

    private func retryImportAddressFetch() {
        importLoadState = .loading
        Task { await fetchImportAddress() }
    }

    private func grantEmailImportConsentAndFetch() {
        EmailImportConsent.grant()
        hasFetchedImportAddress = true
        retryImportAddressFetch()
    }

    /// Findings 2 & 7: the CTA-adjacent guidance line, mirroring
    /// `TripFormView.ctaSection` — a save failure (freshest, most specific
    /// problem) takes priority over the advisory "what's missing" hint, and
    /// either replaces the old fully-silent disabled state.
    ///
    /// Phase 3 (P3.6): sticky — `body` places this outside the `ScrollView`
    /// now, not that view's last scrollable item, and flights gain the
    /// secondary "Save & add the return leg" action alongside Save.
    private var footerBar: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let saveError {
                Text(saveError.message)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.rose)
            } else if let dismissError {
                Text(dismissError)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.rose)
            } else if let hint = missingNameHint {
                Text(hint)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }
            Button {
                save()
            } label: {
                Text(saveButtonTitle)
                    .font(Typo.body(weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(isValid ? Palette.onAmber : Palette.slate)
                    .padding(.vertical, Spacing.md)
                    .background(
                        isValid ? Palette.amber : Palette.mist, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    )
                    .shadow(color: isValid ? Palette.amberGlow.opacity(0.45) : .clear, radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(!isValid || isDismissingSuggestion || isSaving)

            // P3.6: flights come in pairs — saves the leg on screen, then
            // resets the form in place for the reversed return leg (see
            // `saveAndAddReturnLeg`'s doc comment). Same validation gate as
            // Save itself; it runs the identical save path.
            if showsReturnLegAction {
                Button {
                    saveAndAddReturnLeg()
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: returnLegIconSize, weight: .semibold))
                            // Decorative — the label says the same thing.
                            .accessibilityHidden(true)
                        Text("Save & add the return leg")
                            .font(Typo.body(weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    // Fix-round D3: `Palette.ink` (~14.4:1 light, ~10.9:1
                    // dark on this fill), not `amberInk` — that pairing on
                    // `amberSoft` measures ~4.45:1 in light mode, under the
                    // 4.5:1 AA bar (the exact pairing `BoardingPassCard
                    // .swift`'s own day-badge comment already flags/avoids).
                    .foregroundStyle(isValid ? Palette.ink : Palette.slate)
                    .padding(.vertical, Spacing.md)
                    .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(!isValid || isDismissingSuggestion || isSaving)
            }

            // EI-2: a shared triage queue (`docs/EMAIL_IMPORT_PLAN.md`
            // decisions: "any companion or organizer" can dismiss, not just
            // whoever forwarded the email) — visible only while reviewing an
            // unconfirmed suggestion, never for a normal add/edit.
            if isReviewingSuggestion {
                Button(role: .destructive) {
                    Task { await dismissSuggestion() }
                } label: {
                    HStack {
                        if isDismissingSuggestion {
                            ProgressView().tint(Palette.rose)
                        }
                        Text("Dismiss")
                            .font(Typo.body(weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Palette.rose)
                    .padding(.vertical, Spacing.md)
                    .background(Palette.roseSoft, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isDismissingSuggestion)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.md)
        .padding(.bottom, Spacing.lg)
        .background(Palette.paper)
        .overlay(alignment: .top) {
            Rectangle().fill(Palette.mist).frame(height: 1)
        }
    }

    private var saveButtonTitle: String {
        if isReviewingSuggestion { return "Confirm booking" }
        return isEditing ? "Save changes" : "Add \(category.displayName.lowercased()) to itinerary"
    }

    /// Finding 7: names the specific missing field driving a disabled Save,
    /// instead of leaving the dimmed button as the only signal. `nil` once
    /// that category's name/code requirement is met — the date-order hints
    /// (`flightEndAfterStart` etc.) stay on their own section-local captions,
    /// this only covers the "nothing typed yet" case.
    private var missingNameHint: String? {
        switch category {
        case .flight:
            let hasFrom = !fromIATA.trimmingCharacters(in: .whitespaces).isEmpty
            let hasTo = !toIATA.trimmingCharacters(in: .whitespaces).isEmpty
            return (hasFrom && hasTo) ? nil : "Enter both airport codes to add this flight."
        case .hotel:
            return stayHasName ? nil : "Enter a hotel name to add this stay."
        case .activity:
            return activityTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter a title to add this activity." : nil
        case .food:
            return foodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "Enter a restaurant name to add this reservation." : nil
        case .transport:
            return transportHasName ? nil : "Enter a title or provider to add this transport."
        }
    }

    // MARK: - Validation

    var isValid: Bool {
        switch category {
        case .flight:
            return !fromIATA.trimmingCharacters(in: .whitespaces).isEmpty
                && !toIATA.trimmingCharacters(in: .whitespaces).isEmpty
                && flightEndAfterStart
        case .hotel:
            return stayHasName && stayEndAfterStart
        case .activity:
            return !activityTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .food:
            return !foodName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .transport:
            return transportHasName && transportEndAfterStart
        }
    }

    // MARK: - Save

    /// Finding 1: used to hard-guard on `authManager.userId`, which made
    /// Save silently no-op (the sheet didn't even dismiss) for a signed-out
    /// local trip creator — the exact persona `TripView.canAddItems`
    /// legitimately grants write access to. Guards on `isValid` alone now;
    /// the create branch falls back to `tripCreatedBy` (the signed-out
    /// creator's own uid) when `authManager.userId` is `nil`, matching
    /// `TripView.canAddItems`'s "signed out ⇒ legitimately-permitted local
    /// creator" rule.
    ///
    /// P3.6: `andDismiss` defaults `true` for the ordinary Save button —
    /// `saveAndAddReturnLeg()` is the one caller that passes `false`, so it
    /// can keep this same sheet open and reset it for the return leg
    /// instead of closing right after the outbound leg lands.
    ///
    /// Fix-round D2: `guard !isSaving` (set `true` immediately below, before
    /// any other work) is what actually closes the double-tap window — see
    /// `isSaving`'s own doc comment for why the footer's `.disabled` alone
    /// isn't enough. Every exit below resets `isSaving` back to `false`
    /// EXCEPT the final dismissing one: that path tears the view down
    /// anyway, so there's nothing left to re-enable.
    private func save(andDismiss: Bool = true) {
        guard isValid, !isSaving else { return }
        isSaving = true
        saveError = nil
        dismissError = nil
        let now = Date()
        var fields = composedFields()
        fields.details.tags = Array(selectedTags)

        if let editing {
            // EI-2: captured before mutating `editing.status` below, since
            // `isReviewingSuggestion` reads it live and would otherwise
            // already read `false` by the time `toastMessage` needs it.
            let wasReviewingSuggestion = isReviewingSuggestion
            editing.category = category
            editing.title = fields.title
            editing.startsAt = fields.startsAt
            editing.endsAt = fields.endsAt
            editing.tz = fields.tz
            editing.locationName = fields.locationName
            editing.locationLat = fields.locationLat
            editing.locationLng = fields.locationLng
            editing.confirmation = fields.confirmation
            editing.details = fields.details
            editing.updatedAt = now
            // `nil` while signed out — honest: this device's edit hasn't
            // been attributed to a signed-in account yet.
            editing.updatedBy = authManager.userId
            // EI-2: review-and-confirm flips `suggested` -> `confirmed` as
            // part of the exact same write — it rides the normal SwiftData
            // save + `enqueueUpsert` outbox path below, not a separate
            // request, so it's offline-safe like any other edit.
            if wasReviewingSuggestion {
                editing.status = .confirmed
            }
            do {
                try modelContext.save()
            } catch {
                // Finding 2: the write failed — stop here, before enqueuing
                // sync, reconciling assignees, toasting, or dismissing, so a
                // failed save never reads to the user as a successful one.
                saveError = .writeFailed
                isSaving = false
                return
            }
            let dto = editing.toDTO()
            let rowId = editing.id
            Task { await syncEngine?.enqueueUpsert(table: .itineraryItems, rowId: rowId, tripId: tripId, payload: dto) }
            reconcileAssignees(itemId: rowId)
            onToast(toastMessage(wasReviewingSuggestion ? "confirmed" : "updated"))
        } else {
            guard let creatorId = authManager.userId ?? tripCreatedBy else {
                isSaving = false
                return
            }
            let item = ItineraryItem(
                id: UUID(), tripId: tripId, categoryRaw: category.rawValue, title: fields.title,
                startsAt: fields.startsAt, endsAt: fields.endsAt, tz: fields.tz,
                locationName: fields.locationName, locationLat: fields.locationLat, locationLng: fields.locationLng,
                confirmation: fields.confirmation, notes: nil, detailsJSON: "{}",
                statusRaw: ItemStatus.confirmed.rawValue, createdBy: creatorId,
                createdAt: now, updatedAt: now, updatedBy: nil
            )
            item.details = fields.details
            modelContext.insert(item)
            do {
                try modelContext.save()
            } catch {
                saveError = .writeFailed
                isSaving = false
                return
            }
            let dto = item.toDTO()
            let rowId = item.id
            Task { await syncEngine?.enqueueUpsert(table: .itineraryItems, rowId: rowId, tripId: tripId, payload: dto) }
            reconcileAssignees(itemId: rowId)
            onToast(toastMessage("added"))
        }

        // Haptics: both the add and edit branches above only reach this
        // point once their own `modelContext.save()` actually succeeded —
        // a failed save returns early (`saveError = .writeFailed`) without
        // ever reaching here, so this can't fire on a save that didn't land.
        didSave.toggle()
        persistZoneDefaults()
        if andDismiss {
            dismiss()
        } else {
            // Return-leg path: the sheet stays open and reusable, so the
            // guard must release — otherwise the return leg's own Save
            // would stay permanently disabled.
            isSaving = false
        }
    }

    /// "Save & add the return leg" (docs/UX_REDESIGN_ROADMAP.md P3.6):
    /// saves the leg on screen exactly like the primary Save button
    /// (`andDismiss: false` only changes whether the sheet closes
    /// afterward), then — only once that write actually landed
    /// (`saveError == nil`) — resets the form in place to
    /// `Self.returnLegFields`'s reversed/cleared values, ready for the
    /// return leg's own Save. `editing` stays `nil` for the whole life of an
    /// add-mode sheet (the only mode `showsReturnLegAction` allows this CTA
    /// in), so that second Save always takes `save()`'s "create a new item"
    /// branch — never re-editing the leg just saved.
    ///
    /// Fix-round D1 (data loss): `save()`'s own `reconcileAssignees(itemId:)`
    /// ends by setting `originalAssigneeProfileIds = selectedAssigneeProfileIds`
    /// — correct for editing one persistent item over time, but leg 2 is a
    /// *different* item with zero real `ItemAssignee` rows of its own. Left
    /// alone, leg 2's `reconcileAssignees` would then diff the still-selected
    /// people against that stale "already applied" snapshot, compute
    /// `toAdd = ∅`, and silently persist no assignees at all while the UI
    /// keeps showing them selected. Resetting to `[]` here — after leg 1's
    /// save, before the reset below — makes leg 2's reconcile see every
    /// selected person as new, exactly like a fresh item should.
    private func saveAndAddReturnLeg() {
        guard isValid else { return }
        save(andDismiss: false)
        guard saveError == nil else { return }
        originalAssigneeProfileIds = []
        let next = Self.returnLegFields(
            fromIATA: fromIATA, toIATA: toIATA,
            departureZone: departureZone, arrivalZone: arrivalZone,
            flightDate: flightDate
        )
        fromIATA = next.fromIATA
        toIATA = next.toIATA
        departureZone = next.departureZone
        arrivalZone = next.arrivalZone
        flightDate = next.flightDate
        arrivalDate = next.arrivalDate
        departsTime = next.departsTime
        arrivesTime = next.arrivesTime
        seat = next.seat
        terminal = next.terminal
        gate = next.gate
        confirmation = next.confirmation
    }

    /// The pure transform behind `saveAndAddReturnLeg()` above — a plain
    /// value type (not a direct `@State` mutation) so
    /// `AddItemSheetReturnLegTests` can pin every field without standing up
    /// the view itself, mirroring `flightInstants`/`transportInstants`'s
    /// existing "pure function computes, the view applies it" split.
    struct ReturnLegFields: Equatable {
        var fromIATA: String
        var toIATA: String
        var departureZone: TimeZone
        var arrivalZone: TimeZone
        var flightDate: Date
        var arrivalDate: Date
        var departsTime: Date
        var arrivesTime: Date?
        var seat: String
        var terminal: String
        var gate: String
        var confirmation: String
    }

    /// Reverses the route, swaps the zones, advances the date a day, and
    /// clears everything specific to ONE leg's own schedule. Airline/flight
    /// number are deliberately NOT part of this transform — most return
    /// legs fly the same carrier, so `saveAndAddReturnLeg()` leaves those
    /// two fields untouched rather than clearing them here. `arrivalDate`
    /// resets to the same day as the new leg's own `flightDate` (same-day,
    /// same as a blank new item — see `arrivalDate`'s own default in
    /// `init`), and `arrivesTime` resets to `nil` (P7c: "not yet set,"
    /// matching a brand-new item — no fabricated leg-2 arrival either).
    /// `departsTime` resets to `Date()`, the same "blank new flight" default
    /// `init()` uses, not the outbound leg's own clock time — a return leg
    /// is a different day, so carrying over the same time would rarely be
    /// right. `readingCalendar` mirrors `flightInstants`/`transportInstants`'s
    /// own injectable-calendar parameter (deterministic in tests regardless
    /// of the machine's own calendar).
    static func returnLegFields(
        fromIATA: String, toIATA: String,
        departureZone: TimeZone, arrivalZone: TimeZone,
        flightDate: Date,
        readingCalendar: Calendar = .current
    ) -> ReturnLegFields {
        let nextFlightDate = readingCalendar.date(byAdding: .day, value: 1, to: flightDate) ?? flightDate
        return ReturnLegFields(
            fromIATA: toIATA, toIATA: fromIATA,
            departureZone: arrivalZone, arrivalZone: departureZone,
            flightDate: nextFlightDate, arrivalDate: nextFlightDate,
            departsTime: Date(), arrivesTime: nil,
            seat: "", terminal: "", gate: "", confirmation: ""
        )
    }

    /// "Flight added", "Flight added — will sync when you're back" when
    /// offline (so an edit made on the plane visibly reassures it isn't
    /// lost), or the signed-out variant (finding 1) when there's no signed-
    /// in session to attribute the write to — takes precedence over the
    /// offline variant since "signed out" is the more specific, more
    /// actionable fact (the offline case still applies once they sign in).
    private func toastMessage(_ verb: String) -> String {
        let base = "\(category.displayName) \(verb)"
        if authManager.userId == nil {
            return "\(base) \u{2014} you\u{2019}re signed out, so it won\u{2019}t sync until you sign back in."
        }
        return syncStatus.isOffline ? "\(base) \u{2014} will sync when you\u{2019}re back" : base
    }

    // MARK: - EI-2: dismiss an email-import suggestion

    /// `dismiss_email_import_item` (`docs/EMAIL_IMPORT_PLAN.md`): a live-only
    /// RPC call, not an outbox op — matching how `claim_invite`/`peek_invite`
    /// are called directly via `Supa.rpc` (App/AppRouter.swift), since this
    /// is a one-shot server-side transaction (delete the suggested row +
    /// mark its `email_imports` row rejected) rather than a field edit that
    /// makes sense to queue offline. On success, the item is also deleted
    /// from the local mirror immediately (rather than waiting on the next
    /// pull/realtime delete) so the inbox updates without a visible delay.
    private func dismissSuggestion() async {
        guard let editing else { return }
        isDismissingSuggestion = true
        dismissError = nil
        do {
            try await Supa.rpcVoid(
                "dismiss_email_import_item", params: DismissEmailImportItemParams(pItemId: editing.id)
            )
            modelContext.delete(editing)
            try? modelContext.save()
            isDismissingSuggestion = false
            onToast("Booking dismissed")
            dismiss()
        } catch {
            isDismissingSuggestion = false
            dismissError = "Couldn\u{2019}t dismiss this booking. Check your connection and try again."
        }
    }

    // MARK: - Family: assignees + tags (this milestone's brief §3)

    private var myRole: TripRole? {
        guard let userId = authManager.userId else { return nil }
        return members.first { $0.userId == userId }?.role
    }

    /// Gates the "Who's this for?" section — the exact `item_assignees`
    /// RLS rule (confirmed live): organizer may assign on any item; a
    /// companion only on one they created. A brand-new item
    /// (`editing == nil`) has no `createdBy` yet — whoever can add it at
    /// all becomes its creator, so `ItemPermissions.canAdd` is the
    /// equivalent gate for that case.
    var canManageAssignees: Bool {
        if let editing {
            return ItemPermissions.canEdit(item: editing, role: myRole, userId: authManager.userId)
        }
        return ItemPermissions.canAdd(role: myRole)
    }

    /// Seeds the multi-select from `existingAssignees` exactly once —
    /// `@Query` results aren't available synchronously in `init` (unlike
    /// `editing`'s other fields), so this runs from `.task` on first
    /// appearance instead. Guarded by `hasLoadedAssignees` so a later
    /// re-fire (e.g. an unrelated pull touching this trip) never clobbers
    /// selections the user is mid-edit on.
    private func seedAssigneesIfNeeded() {
        guard !hasLoadedAssignees else { return }
        hasLoadedAssignees = true
        let ids = Set(existingAssignees.map(\.profileId))
        selectedAssigneeProfileIds = ids
        originalAssigneeProfileIds = ids
    }

    /// The pure diff behind `reconcileAssignees` below — which profile ids
    /// need an `ItemAssignee` insert/delete to bring the persisted set in
    /// line with what's currently selected. Factored out (mirroring
    /// `flightInstants`/`returnLegFields`'s "pure function computes, the
    /// view applies it" split) so `AddItemSheetAssigneeReconciliationTests`
    /// can pin fix-round D1's exact regression — `original` reset to `[]`
    /// between two saves of two *different* items — without a live
    /// `ModelContext`.
    static func assigneeReconciliation(
        selected: Set<UUID>, original: Set<UUID>
    ) -> (toAdd: Set<UUID>, toRemove: Set<UUID>) {
        (selected.subtracting(original), original.subtracting(selected))
    }

    /// Diffs `selectedAssigneeProfileIds` against the snapshot captured at
    /// seed time and applies exactly the additions/removals — not a
    /// wholesale delete-then-reinsert, so an unrelated field save doesn't
    /// churn rows nobody actually changed.
    private func reconcileAssignees(itemId: UUID) {
        let (toAdd, toRemove) = Self.assigneeReconciliation(
            selected: selectedAssigneeProfileIds, original: originalAssigneeProfileIds
        )

        for profileId in toAdd {
            let assignee = ItemAssignee(itemId: itemId, profileId: profileId)
            modelContext.insert(assignee)
            // Finding 2 (companion hardening): the item itself is already
            // safely persisted by this point, so a failure here isn't worth
            // the CTA-level `saveError` treatment — but it shouldn't be
            // silent either, hence the assert instead of a bare `try?`.
            do {
                try modelContext.save()
            } catch {
                assertionFailure("assignee persist failed: \(error)")
            }
            let dto = assignee.toDTO()
            let rowId = assignee.id
            Task { await syncEngine?.enqueueUpsert(table: .itemAssignees, rowId: rowId, tripId: tripId, payload: dto) }
        }

        for profileId in toRemove {
            let compositeId = ItemAssignee.compositeId(itemId: itemId, profileId: profileId)
            if let existing = existingAssignees.first(where: { $0.id == compositeId }) {
                modelContext.delete(existing)
                do {
                    try modelContext.save()
                } catch {
                    assertionFailure("assignee persist failed: \(error)")
                }
            }
            Task { await syncEngine?.enqueueDeleteItemAssignee(itemId: itemId, profileId: profileId, tripId: tripId) }
        }

        originalAssigneeProfileIds = selectedAssigneeProfileIds
    }

    private func persistZoneDefaults() {
        guard category == .flight else { return }
        UserDefaults.standard.set(departureZone.identifier, forKey: Self.lastDepartureTZKey)
        UserDefaults.standard.set(arrivalZone.identifier, forKey: Self.lastArrivalTZKey(tripId))
    }

    // MARK: - Field composition (one row per category → ItineraryItem's shape)

    struct ComposedFields {
        var title: String
        var startsAt: Date
        var endsAt: Date?
        var tz: String
        var details: ItemDetails
        var confirmation: String?
        var locationName: String
        var locationLat: Double?
        var locationLng: Double?
    }

    func composedFields() -> ComposedFields {
        switch category {
        case .flight: return flightFields()
        case .hotel: return stayFields()
        case .activity: return activityFields()
        case .food: return foodFields()
        case .transport: return transportFields()
        }
    }

    /// A transport item is named by either its title or its provider — a rental
    /// is often just "Hertz" with no distinct title, so requiring both was
    /// redundant (persona dry-run).
    var transportHasName: Bool {
        !transportTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !provider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The zone actually applied to the drop-off: the pickup zone unless the
    /// user opted into a different one.
    var effectiveDropoffZone: TimeZone { transportDropoffDiffZone ? dropoffZone : pickupZone }

    /// Whether a transport item's drop-off is strictly after its pickup — the
    /// same "end after start" rule Stay enforces, so a rental can't save with a
    /// zero or negative duration. Drives both `isValid` and the form's hint.
    var transportEndAfterStart: Bool {
        let (start, end) = Self.transportInstants(
            pickupDate: transportDate, pickupTime: pickupTime, pickupTz: pickupZone,
            dropoffDate: dropoffDate, dropoffTime: dropoffTime, dropoffTz: effectiveDropoffZone
        )
        return end > start
    }

    /// Composes a transport item's start (pickup) and end (drop-off) instants
    /// from two independent date pickers, so a multi-night rental (pick up
    /// Thursday, return Saturday) is expressible — unlike the old pickup-date +
    /// 0/1-day-offset shape. Pure; exposed for tests.
    static func transportInstants(
        pickupDate: Date, pickupTime: Date, pickupTz: TimeZone,
        dropoffDate: Date, dropoffTime: Date, dropoffTz: TimeZone,
        readingCalendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let start = ItemTimeCombining.combine(date: pickupDate, timeOfDay: pickupTime, targetTz: pickupTz, readingCalendar: readingCalendar)
        let end = ItemTimeCombining.combine(date: dropoffDate, timeOfDay: dropoffTime, targetTz: dropoffTz, readingCalendar: readingCalendar)
        return (start, end)
    }

    private func transportFields() -> ComposedFields {
        let (start, end) = Self.transportInstants(
            pickupDate: transportDate, pickupTime: pickupTime, pickupTz: pickupZone,
            dropoffDate: dropoffDate, dropoffTime: dropoffTime, dropoffTz: effectiveDropoffZone
        )
        var details = ItemDetails.empty
        details.provider = Self.trimmedOrNil(provider)
        details.dropoffLocation = Self.trimmedOrNil(dropoffText)
        // Always recorded (as for flights) so `effectiveTz` is well-defined even
        // for a same-zone rental, and the tz-shift chip works for a zone-crossing
        // train/ferry.
        details.arrivalTz = effectiveDropoffZone.identifier

        return ComposedFields(
            title: Self.trimmedOrNil(transportTitle) ?? Self.trimmedOrNil(provider) ?? "Transport",
            startsAt: start, endsAt: end, tz: pickupZone.identifier,
            details: details, confirmation: Self.trimmedOrNil(confirmation),
            locationName: locationText, locationLat: locationLat, locationLng: locationLng
        )
    }

    /// P7c (award audit #4): `true` once the user has actually set a real
    /// arrival (`arrivesTime != nil`) — `false` means there's nothing real
    /// yet to validate or preview a duration/day-offset from, so
    /// `flightEndAfterStart` doesn't block Save on it and `flightFields()`
    /// leaves `endsAt` `nil` (route-only, same as Activity/Food's own "no
    /// end time" shape).
    var hasSetArrival: Bool { arrivesTime != nil }

    /// Whether a flight's arrival instant is strictly after its departure
    /// instant — the same "end after start" rule Stay/Transport enforce, so
    /// a same-day arrival clock earlier than departure can't save as a
    /// negative-duration flight. Compares the *absolute instants*
    /// `flightInstants` composes, not wall-clock times: a westward
    /// cross-zone flight can have an arrival wall-clock earlier than
    /// departure's yet still land on a later instant, and that is valid.
    /// Vacuously true while arrival isn't set yet (`hasSetArrival == false`)
    /// — there's nothing real to compare. Drives both `isValid` and the
    /// form's hint.
    var flightEndAfterStart: Bool {
        guard let arrivesTime else { return true }
        let (start, end) = Self.flightInstants(
            departureDate: flightDate, departsTime: departsTime, departureZone: departureZone,
            arrivalDate: arrivalDate, arrivesTime: arrivesTime, arrivalZone: arrivalZone
        )
        return end > start
    }

    /// Finding 1: whether a stay's hotel name has been entered — factored
    /// out so `staySection`'s date-order hint can gate on it first, the same
    /// way `transportHasName` already gates transport's hint (see
    /// `transportEndAfterStart` above), instead of showing "Check-out must
    /// be after check-in" on a blank, untouched form.
    var stayHasName: Bool { !stayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether a stay's check-out is strictly after check-in — the same "end
    /// after start" rule flight/transport enforce. Drives both `isValid` and
    /// the form's hint (gated on `stayHasName` there).
    var stayEndAfterStart: Bool {
        let start = ItemTimeCombining.combine(date: checkInDate, timeOfDay: checkInTime, targetTz: stayZone)
        let end = ItemTimeCombining.combine(date: checkOutDate, timeOfDay: checkOutTime, targetTz: stayZone)
        return end > start
    }

    /// Composes a flight item's departure and arrival instants from two
    /// independent date+time+zone pairs — the same math `flightFields()`
    /// needs to actually save the item, factored out (mirroring
    /// `transportInstants` above) so validation and the save path share one
    /// source of truth. P7c: replaces the old single shared `flightDate` +
    /// boolean `nextDay` shape (capped at 0 or +1 day, and — worse — that
    /// default was guessed from wall-clock minutes alone, blind to either
    /// zone: a late-enough departure paired with an unrelated stale arrival
    /// default could need +2 days to reach a valid arrival at all, which the
    /// old boolean had no way to express). An explicit `arrivalDate` makes
    /// any day gap directly representable and the day badge/duration a pure
    /// output of the two real instants, never a separate toggle to keep in
    /// sync. Pure; exposed for tests.
    static func flightInstants(
        departureDate: Date, departsTime: Date, departureZone: TimeZone,
        arrivalDate: Date, arrivesTime: Date, arrivalZone: TimeZone,
        readingCalendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let start = ItemTimeCombining.combine(
            date: departureDate, timeOfDay: departsTime, targetTz: departureZone, readingCalendar: readingCalendar
        )
        let end = ItemTimeCombining.combine(
            date: arrivalDate, timeOfDay: arrivesTime, targetTz: arrivalZone, readingCalendar: readingCalendar
        )
        return (start, end)
    }

    private func flightFields() -> ComposedFields {
        let from = fromIATA.trimmingCharacters(in: .whitespaces).uppercased()
        let to = toIATA.trimmingCharacters(in: .whitespaces).uppercased()
        let start = ItemTimeCombining.combine(date: flightDate, timeOfDay: departsTime, targetTz: departureZone)
        // P7c: no fabricated arrival — `endsAt` stays `nil` (route-only,
        // same as Activity/Food's own shape) until the user actually sets
        // one; `flightPreviewModel` reuses this same field, so the live
        // pass can never assert a duration/day badge that isn't real.
        let end = arrivesTime.map { arrives in
            Self.flightInstants(
                departureDate: flightDate, departsTime: departsTime, departureZone: departureZone,
                arrivalDate: arrivalDate, arrivesTime: arrives, arrivalZone: arrivalZone
            ).end
        }
        let title = [
            airline.trimmingCharacters(in: .whitespacesAndNewlines),
            flightNo.trimmingCharacters(in: .whitespacesAndNewlines)
        ].filter { !$0.isEmpty }.joined(separator: " ")

        var details = ItemDetails.empty
        details.airline = Self.trimmedOrNil(airline)
        details.flightNo = Self.trimmedOrNil(flightNo)
        details.fromIATA = from.isEmpty ? nil : from
        details.toIATA = to.isEmpty ? nil : to
        details.seat = Self.trimmedOrNil(seat)
        details.terminal = Self.trimmedOrNil(terminal)
        details.gate = Self.trimmedOrNil(gate)
        // Always recorded, even when it matches the departure zone — keeps
        // `effectiveTz` well-defined for a same-zone domestic flight too.
        details.arrivalTz = arrivalZone.identifier

        return ComposedFields(
            title: title.isEmpty ? "Flight" : title,
            startsAt: start, endsAt: end, tz: departureZone.identifier,
            details: details, confirmation: Self.trimmedOrNil(confirmation),
            locationName: from, locationLat: nil, locationLng: nil
        )
    }

    /// Phase 3 (P3.2): the flight route section's own live preview — reuses
    /// `BoardingPassContent.make(for:)`, the exact same `ItineraryItem ->
    /// BoardingPassCard.Model` adapter the itinerary timeline calls, over a
    /// transient `ItineraryItem` (built from this sheet's own
    /// `flightFields()`, never inserted into `modelContext`) so the preview
    /// can never disagree with what saving would actually produce. Force-
    /// unwrapped: the transient item is always stamped `.flight`, the one
    /// category `BoardingPassContent.make` ever returns `nil` for. Not
    /// `private` — `AddItemFormSections.flightSection` (a different file,
    /// same type) reads it; see `tagIconSize`'s doc comment for the
    /// identical reasoning.
    ///
    /// P7c (award audit #4): inherits "no fabricated arrival" for free —
    /// `flightFields().endsAt` is `nil` until `hasSetArrival`, and
    /// `BoardingPassContent.make`/`BoardingPassCard` already render a `nil`
    /// destination date as route-only (no duration, no day badge), per P1.
    var flightPreviewModel: BoardingPassCard.Model {
        let fields = flightFields()
        let transient = ItineraryItem(
            id: UUID(), tripId: tripId, categoryRaw: ItemCategory.flight.rawValue, title: fields.title,
            startsAt: fields.startsAt, endsAt: fields.endsAt, tz: fields.tz,
            locationName: fields.locationName, locationLat: fields.locationLat, locationLng: fields.locationLng,
            confirmation: fields.confirmation, notes: nil, detailsJSON: "{}",
            statusRaw: ItemStatus.confirmed.rawValue, createdBy: nil,
            createdAt: .now, updatedAt: .now, updatedBy: nil
        )
        transient.details = fields.details
        return BoardingPassContent.make(for: transient)!
    }

    private func stayFields() -> ComposedFields {
        let start = ItemTimeCombining.combine(date: checkInDate, timeOfDay: checkInTime, targetTz: stayZone)
        let end = ItemTimeCombining.combine(date: checkOutDate, timeOfDay: checkOutTime, targetTz: stayZone)
        var details = ItemDetails.empty
        details.room = Self.trimmedOrNil(room)

        return ComposedFields(
            title: Self.trimmedOrNil(stayName) ?? "Stay",
            startsAt: start, endsAt: end, tz: stayZone.identifier,
            details: details, confirmation: Self.trimmedOrNil(confirmation),
            locationName: locationText, locationLat: locationLat, locationLng: locationLng
        )
    }

    private func activityFields() -> ComposedFields {
        let start = ItemTimeCombining.combine(date: activityDate, timeOfDay: activityTime, targetTz: activityZone)
        var details = ItemDetails.empty
        details.ticketRef = Self.trimmedOrNil(ticketRef)
        details.address = address

        return ComposedFields(
            title: Self.trimmedOrNil(activityTitle) ?? "Activity",
            startsAt: start, endsAt: nil, tz: activityZone.identifier,
            details: details,
            // BUILD_PLAN.md §3.3: an activity's `details.ticket_ref` IS its
            // booking/confirmation code — mirrored onto the top-level
            // `confirmation` column so the ticket glyph, Bookings tab, and
            // boarding-pass grid (all keyed on `item.confirmation`) work
            // uniformly across every category.
            confirmation: Self.trimmedOrNil(ticketRef),
            locationName: locationText, locationLat: locationLat, locationLng: locationLng
        )
    }

    private func foodFields() -> ComposedFields {
        let start = ItemTimeCombining.combine(date: foodDate, timeOfDay: foodTime, targetTz: foodZone)
        var details = ItemDetails.empty
        details.partySize = Int(partySize.trimmingCharacters(in: .whitespaces))
        details.reservationName = Self.trimmedOrNil(reservationName)
        details.address = address

        return ComposedFields(
            title: Self.trimmedOrNil(foodName) ?? "Food",
            startsAt: start, endsAt: nil, tz: foodZone.identifier,
            // Finding 5: Food now has its own confirmation-code field
            // (`foodSection`) — mirrored onto the top-level `confirmation`
            // column, same as flight/stay/transport, so it earns the ticket
            // glyph and shows up in Bookings/the boarding-pass grid.
            details: details, confirmation: Self.trimmedOrNil(confirmation),
            locationName: locationText, locationLat: locationLat, locationLng: locationLng
        )
    }

    /// Phase 3 (P3.3): the seat/terminal/gate/confirmation `DisclosureGroup`'s
    /// one-line collapsed summary — "14C · 1 · 22 · QK7P2M", each empty
    /// field simply dropped (not its own em-dash placeholder) rather than
    /// padding the string with filler, and a single em-dash for the whole
    /// summary when all four are blank. Mirrors `BookingDetailView
    /// .terminalGateText`'s existing "join what's set, dash when nothing
    /// is" convention rather than inventing a second one. Pure/static so
    /// `AddItemSheetFlightDetailsSummaryTests` can exercise every
    /// combination without standing up the sheet.
    static func flightDetailsSummary(seat: String, terminal: String, gate: String, confirmation: String) -> String {
        let parts = [seat, terminal, gate, confirmation]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? "\u{2014}" : parts.joined(separator: " \u{00B7} ")
    }

    static func trimmedOrNil(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Re-anchors the wall-clock components of `instant` (as read in `tz`)
    /// onto the device's own calendar, so a `DatePicker` — which always
    /// renders using `.current` — displays "08:20" for an 08:20-New-York
    /// instant regardless of what zone the device itself is in. The save
    /// path's `ItemTimeCombining.combine(readingCalendar: .current)` is the
    /// exact inverse of this, so the round trip lands back on the same
    /// instant as long as the target zone is unchanged.
    static func pickerDate(from instant: Date, in tz: TimeZone) -> Date {
        var source = Calendar(identifier: .gregorian)
        source.timeZone = tz
        let components = source.dateComponents([.year, .month, .day, .hour, .minute, .second], from: instant)

        var device = Calendar(identifier: .gregorian)
        device.timeZone = .current
        return device.date(from: components) ?? instant
    }

    static func timeOfDay(hour: Int, minute: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date()) ?? Date()
    }
}

/// `dismiss_email_import_item(p_item_id uuid)` — see `dismissSuggestion()`'s
/// doc comment above.
private struct DismissEmailImportItemParams: Encodable {
    let pItemId: UUID
}

/// Phase 3 (docs/UX_REDESIGN_ROADMAP.md P3.1): the type-tile's own copy —
/// verbs ("what am I adding") instead of `ItemCategory.displayName`'s
/// nouns. Not folded into `displayName` itself: that property also feeds
/// `BookingsTabView`'s section headers, `TimelineCardRow`/
/// `SuggestedItemsSheet`'s VoiceOver category word, and this sheet's own
/// title/toast/save-button copy — none of which this milestone's brief
/// touches. Not `private` only so `AddItemSheetVerbLabelTests` can pin the
/// mapping directly; `categoryTile` is still its one real call site.
extension ItemCategory {
    var addSheetVerbLabel: String {
        switch self {
        case .flight: "Flight"
        case .hotel: "Stay"
        case .activity: "Do"
        case .food: "Eat"
        case .transport: "Ride"
        }
    }
}
