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
    /// Finding 2: `categorySelector`'s AX-size horizontal-scroll branch,
    /// same `isAccessibilitySize` convention as `TripView.tabBar()`.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    @State var arrivesTime = Date()
    @State var arrivalZone: TimeZone = .current
    /// `nil` = follow `ItemTimeCombining.suggestedArrivalDayOffset`'s
    /// auto-detect; `true`/`false` once the user taps the "+1 day" chip.
    @State var arrivalDayOffsetOverride: Bool?
    @State var seat = ""
    @State var terminal = ""
    @State var gate = ""

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
    // `dropoffText` is the drop-off place; `arrivalDayOffsetOverride` (shared
    // with flight) drives the "+1 day" chip.
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
        var arrivesTime: Date
        var arrivalZone: TimeZone
        var arrivalDayOffsetOverride: Bool?
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
                let endsAt = editing.endsAt ?? editing.startsAt
                _arrivesTime = State(initialValue: Self.pickerDate(from: endsAt, in: arrivalTz))
                if editing.endsAt != nil {
                    let startDay = ItineraryTimeZone.localDay(of: editing.startsAt, in: editing.primaryTz)
                    let endDay = ItineraryTimeZone.localDay(of: endsAt, in: arrivalTz)
                    _arrivalDayOffsetOverride = State(initialValue: endDay > startDay)
                }
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
            // default every item to today), and give arrival a 2h head start so
            // the form never opens on a zero-length item with a stray "+1 day"
            // (persona dry-run).
            let dateDefault = tripStartDate > Date() ? tripStartDate : Date()
            _flightDate = State(initialValue: dateDefault)
            _activityDate = State(initialValue: dateDefault)
            _foodDate = State(initialValue: dateDefault)
            _transportDate = State(initialValue: dateDefault)
            _dropoffDate = State(initialValue: dateDefault)
            _arrivesTime = State(initialValue: Date().addingTimeInterval(2 * 3600))
            _checkInDate = State(initialValue: dateDefault)
            _checkInTime = State(initialValue: Self.timeOfDay(hour: 15, minute: 0))
            _checkOutTime = State(initialValue: Self.timeOfDay(hour: 11, minute: 0))
            _checkOutDate = State(initialValue: Calendar.current.date(byAdding: .day, value: 1, to: dateDefault) ?? dateDefault)
        }

        // Captured last, after either branch above has set every field —
        // reading the underscored `@State` wrappers' `wrappedValue` here
        // (rather than the plain properties) is what makes this legal inside
        // `init`, same as `TripFormView.initialValues`.
        initialSnapshot = EditSnapshot(
            category: _category.wrappedValue, selectedTags: _selectedTags.wrappedValue,
            airline: _airline.wrappedValue, flightNo: _flightNo.wrappedValue,
            fromIATA: _fromIATA.wrappedValue, toIATA: _toIATA.wrappedValue,
            flightDate: _flightDate.wrappedValue, departsTime: _departsTime.wrappedValue,
            departureZone: _departureZone.wrappedValue, arrivesTime: _arrivesTime.wrappedValue,
            arrivalZone: _arrivalZone.wrappedValue, arrivalDayOffsetOverride: _arrivalDayOffsetOverride.wrappedValue,
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

    /// Finding 3: the live counterpart to `initialSnapshot` — diffed against
    /// it (plus the separately-tracked assignee set) by `hasChanges`.
    private var currentSnapshot: EditSnapshot {
        EditSnapshot(
            category: category, selectedTags: selectedTags,
            airline: airline, flightNo: flightNo, fromIATA: fromIATA, toIATA: toIATA,
            flightDate: flightDate, departsTime: departsTime, departureZone: departureZone,
            arrivesTime: arrivesTime, arrivalZone: arrivalZone, arrivalDayOffsetOverride: arrivalDayOffsetOverride,
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
                        if !isEditing {
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

                        saveButton
                            .padding(.top, Spacing.xs)
                    }
                    .padding(Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { seedAssigneesIfNeeded() }
        .onAppear {
            #if DEBUG
            // Verify-drill autopilot: preselect the Transport category so the
            // drop-off-date form can be screenshotted without GUI tap automation.
            if editing == nil, ProcessInfo.processInfo.arguments.contains("-uitestAddTransport") {
                category = .transport
            }
            #endif
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
                Text(cat.displayName)
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

    /// Findings 2 & 7: the CTA-adjacent guidance line, mirroring
    /// `TripFormView.ctaSection` — a save failure (freshest, most specific
    /// problem) takes priority over the advisory "what's missing" hint, and
    /// either replaces the old fully-silent disabled state.
    private var saveButton: some View {
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
                    .shadow(color: isValid ? Palette.amber.opacity(0.45) : .clear, radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(!isValid || isDismissingSuggestion)

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
    private func save() {
        guard isValid else { return }
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
                return
            }
            let dto = editing.toDTO()
            let rowId = editing.id
            Task { await syncEngine?.enqueueUpsert(table: .itineraryItems, rowId: rowId, tripId: tripId, payload: dto) }
            reconcileAssignees(itemId: rowId)
            onToast(toastMessage(wasReviewingSuggestion ? "confirmed" : "updated"))
        } else {
            guard let creatorId = authManager.userId ?? tripCreatedBy else { return }
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
        dismiss()
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

    /// Diffs `selectedAssigneeProfileIds` against the snapshot captured at
    /// seed time and applies exactly the additions/removals — not a
    /// wholesale delete-then-reinsert, so an unrelated field save doesn't
    /// churn rows nobody actually changed.
    private func reconcileAssignees(itemId: UUID) {
        let toAdd = selectedAssigneeProfileIds.subtracting(originalAssigneeProfileIds)
        let toRemove = originalAssigneeProfileIds.subtracting(selectedAssigneeProfileIds)

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

    /// The "+1 day" chip state — flight only. Transport no longer uses a
    /// next-day toggle; it has an explicit drop-off date picker instead.
    var effectiveNextDay: Bool { effectiveArrivalIsNextDay }

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

    /// Whether the arrival lands on the calendar day after departure — the
    /// "+1 day" chip's effective state (this milestone's brief: "arrival
    /// wall < departure wall → +1 day, toggleable").
    var effectiveArrivalIsNextDay: Bool {
        arrivalDayOffsetOverride ?? (
            ItemTimeCombining.suggestedArrivalDayOffset(departsTimeOfDay: departsTime, arrivesTimeOfDay: arrivesTime) == 1
        )
    }

    /// Whether a flight's arrival instant is strictly after its departure
    /// instant — the same "end after start" rule Stay/Transport enforce, so
    /// a same-day arrival clock earlier than departure (with the "+1 day"
    /// chip off) can't save as a negative-duration flight. Compares the
    /// *absolute instants* `flightInstants` composes, not wall-clock times:
    /// a westward cross-zone flight can have an arrival wall-clock earlier
    /// than departure's yet still land on a later instant, and that is
    /// valid. Drives both `isValid` and the form's hint.
    var flightEndAfterStart: Bool {
        let (start, end) = Self.flightInstants(
            flightDate: flightDate, departsTime: departsTime, departureZone: departureZone,
            arrivesTime: arrivesTime, arrivalZone: arrivalZone, nextDay: effectiveArrivalIsNextDay
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

    /// Composes a flight item's departure and arrival instants — the same
    /// math `flightFields()` needs to actually save the item, factored out
    /// (mirroring `transportInstants` above) so validation and the save path
    /// share one source of truth. Pure; exposed for tests.
    static func flightInstants(
        flightDate: Date, departsTime: Date, departureZone: TimeZone,
        arrivesTime: Date, arrivalZone: TimeZone, nextDay: Bool,
        readingCalendar: Calendar = .current
    ) -> (start: Date, end: Date) {
        let start = ItemTimeCombining.combine(date: flightDate, timeOfDay: departsTime, targetTz: departureZone, readingCalendar: readingCalendar)
        let end = ItemTimeCombining.combine(
            date: flightDate, timeOfDay: arrivesTime,
            dayOffset: nextDay ? 1 : 0, targetTz: arrivalZone, readingCalendar: readingCalendar
        )
        return (start, end)
    }

    private func flightFields() -> ComposedFields {
        let from = fromIATA.trimmingCharacters(in: .whitespaces).uppercased()
        let to = toIATA.trimmingCharacters(in: .whitespaces).uppercased()
        let (start, end) = Self.flightInstants(
            flightDate: flightDate, departsTime: departsTime, departureZone: departureZone,
            arrivesTime: arrivesTime, arrivalZone: arrivalZone, nextDay: effectiveArrivalIsNextDay
        )
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
