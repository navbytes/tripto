import SwiftData
import SwiftUI

/// Create/edit sheet for a trip (BUILD_PLAN.md §4.1). Every save is a plain
/// SwiftData write on the main context followed by `SyncEngine.enqueue` —
/// the same "instant UI, queued sync" flow every mutation in the app uses.
///
/// Chrome, fields, and CTA are rebuilt on `AddItemSheet`'s branded
/// components (`SheetHeader`, `FormTextField`, `LabeledDatePicker`,
/// `SegmentedControl`) so the two sheets read as one system (UX audit
/// findings F1/F3/F9).
struct TripFormView: View {
    enum Mode {
        case create
        case edit(Trip)
    }

    let mode: Mode
    /// Fires after a successful save, before `dismiss()` — `HomeView`'s
    /// hook (UX audit finding 2) to switch to whichever tab the saved trip
    /// actually files under, so a trip created/edited into the other tab
    /// doesn't silently vanish. `nil` by default so `TripView.swift`'s edit
    /// sheet (which doesn't need this) compiles unchanged.
    var onSaved: ((Trip) -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncEngine) private var syncEngine
    @Environment(AuthManager.self) private var authManager
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var destination: String
    @State private var countryCode: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var tripType: TripType
    @State private var coverGradientKey: String

    /// F6: surfaced above the CTA when `modelContext.save()` throws, instead
    /// of the old silent `try?` — the save simply stops, nothing is
    /// enqueued or dismissed, and the user can retry. Two-case rather than a
    /// bare `String?` so `.signedOut` (a dead end this sheet can't recover
    /// from on its own) survives further edits, while `.writeFailed` (a
    /// transient, retryable write) clears the moment the user touches
    /// anything, same as before — see `isClearedByEditing`.
    private enum SaveError: Equatable {
        case signedOut
        case writeFailed

        var message: String {
            switch self {
            case .signedOut:
                // Finding 7: names the actual consequence instead of an
                // unreachable in-sheet fix (§6.6 plain, honest register) —
                // this sheet has no way to trigger sign-in itself, so
                // telling the user to "sign in again" here was a dead end.
                return "You\u{2019}ve been signed out, so this trip can\u{2019}t be created. Cancel and " +
                    "sign back in \u{2014} what you\u{2019}ve entered here won\u{2019}t be kept."
            case .writeFailed:
                return "Couldn\u{2019}t save the trip. Try again."
            }
        }

        var isClearedByEditing: Bool {
            switch self {
            case .signedOut: return false
            case .writeFailed: return true
            }
        }
    }

    @State private var saveError: SaveError?
    /// F4: gates the "Discard changes?" confirmation on cancel/swipe-dismiss.
    @State private var showDiscardConfirm = false

    /// UX audit finding 5: Trip name -> Destination keyboard flow, so a user
    /// filling the form top-to-bottom never has to reach for the keyboard's
    /// dismiss key or tap the next field by hand. Country dropped out of
    /// this chain when it became a picker (finding 3) rather than a typed
    /// field.
    private enum FocusField {
        case title, destination
    }
    @FocusState private var focusedField: FocusField?

    /// The three tokens `CoverGradient` defines (`"default"` is just an
    /// alias for `dusk`, not a fourth option) — `dusk` is pre-selected for
    /// new trips, matching the schema's own column default.
    private static let gradientOptions = ["dusk", "plum", "moss"]

    /// F4: the field values this sheet opened with, so `hasChanges` can tell
    /// an untouched form from a dirty one. Also `Equatable` (finding 6) so
    /// `currentValues` below can drive a single `.onChange` that clears a
    /// stale `saveError` the moment any field is edited.
    private struct InitialValues: Equatable {
        var title: String
        var destination: String
        var countryCode: String
        var startDate: Date
        var endDate: Date
        var tripType: TripType
        var coverGradientKey: String
    }
    private let initialValues: InitialValues

    init(mode: Mode, onSaved: ((Trip) -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .create:
            let start = Calendar.current.startOfDay(for: .now)
            let end = Calendar.current.date(byAdding: .day, value: 6, to: .now) ?? .now
            _title = State(initialValue: "")
            _destination = State(initialValue: "")
            _countryCode = State(initialValue: "")
            _startDate = State(initialValue: start)
            _endDate = State(initialValue: end)
            _tripType = State(initialValue: .family)
            _coverGradientKey = State(initialValue: "dusk")
            initialValues = InitialValues(
                title: "", destination: "", countryCode: "",
                startDate: start, endDate: end, tripType: .family, coverGradientKey: "dusk"
            )
        case .edit(let trip):
            _title = State(initialValue: trip.title)
            _destination = State(initialValue: trip.destination)
            _countryCode = State(initialValue: trip.countryCode)
            _startDate = State(initialValue: trip.startDate)
            _endDate = State(initialValue: trip.endDate)
            _tripType = State(initialValue: trip.tripType)
            _coverGradientKey = State(initialValue: trip.coverGradient)
            initialValues = InitialValues(
                title: trip.title, destination: trip.destination, countryCode: trip.countryCode,
                startDate: trip.startDate, endDate: trip.endDate,
                tripType: trip.tripType, coverGradientKey: trip.coverGradient
            )
        }
    }

    private var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    private var isDateRangeValid: Bool {
        TripFormValidation.isDateRangeValid(startDate: startDate, endDate: endDate)
    }

    private var isValid: Bool {
        TripFormValidation.isValid(title: title, countryCode: countryCode, startDate: startDate, endDate: endDate)
    }

    /// F4: whether any field has moved from what the sheet opened with.
    /// Dates are compared by calendar day so the create case's default
    /// 7-day range isn't spuriously "dirty."
    private var hasChanges: Bool {
        let calendar = Calendar.current
        return title != initialValues.title
            || destination != initialValues.destination
            || countryCode != initialValues.countryCode
            || calendar.startOfDay(for: startDate) != calendar.startOfDay(for: initialValues.startDate)
            || calendar.startOfDay(for: endDate) != calendar.startOfDay(for: initialValues.endDate)
            || tripType != initialValues.tripType
            || coverGradientKey != initialValues.coverGradientKey
    }

    /// F6: the live snapshot `.onChange` diffs against `initialValues`
    /// (indirectly, via its own previous value) to clear a stale `saveError`
    /// the instant the user edits anything — otherwise e.g. the blank-title
    /// guidance stays stuck on screen after the title is fixed but before
    /// the CTA is tapped again.
    private var currentValues: InitialValues {
        InitialValues(
            title: title, destination: destination, countryCode: countryCode,
            startDate: startDate, endDate: endDate, tripType: tripType, coverGradientKey: coverGradientKey
        )
    }

    /// Bridges `SegmentedControl`'s `String` selection to `tripType` — the
    /// three `TripType` raw values ("family"/"friends"/"solo") capitalized
    /// are exactly the control's option labels.
    private var tripTypeSelection: Binding<String> {
        Binding(
            get: { tripType.rawValue.capitalized },
            set: { newValue in
                if let matched = TripType.allCases.first(where: { $0.rawValue.capitalized == newValue }) {
                    tripType = matched
                }
            }
        )
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeader(title: isEditing ? "Edit trip" : "Plan a new trip", onCancel: cancelTapped)
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.lg) {
                        tripNameField
                        destinationField
                        countryField
                        datesSection
                        tripTypeSection
                        coverSection
                        ctaSection
                    }
                    .padding(Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        .background(
            // Finding 5: surfaces the same "Discard changes?" dialog Cancel
            // uses when a dirty form's swipe-down is blocked by
            // `.interactiveDismissDisabled` below, instead of an unexplained
            // rubber-band.
            SheetDismissAttemptObserver { showDiscardConfirm = true }
        )
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
        .onChange(of: currentValues) { _, _ in
            if saveError?.isClearedByEditing == true {
                saveError = nil
            }
        }
        // Finding 4: only error-toned CTA guidance is announced — see
        // `ctaGuidance`'s doc comment for why the advisory blank-title copy
        // is deliberately excluded.
        .onChange(of: saveError) { _, newValue in
            if let newValue {
                AccessibilityNotification.Announcement(newValue.message).post()
            }
        }
        .task {
            // F5, create mode only — editing an existing trip shouldn't pop
            // the keyboard the moment the sheet appears. A short delay
            // rather than `.defaultFocus` here: this view is hosted in a
            // sheet-presented `NavigationStack`, where `.defaultFocus`'s
            // timing relative to the sheet's own presentation animation is
            // unreliable; a delayed explicit set is the dependable version
            // of the same intent. Guarded by `focusedField == nil` (finding
            // 1) so a user who's already tapped into Destination within the
            // delay isn't yanked back to Title.
            if case .create = mode {
                try? await Task.sleep(for: .milliseconds(500))
                if focusedField == nil {
                    focusedField = .title
                }
            }
        }
    }

    // MARK: - Fields

    private var tripNameField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            FormTextField(
                label: "Trip name", text: $title, placeholder: "Lisbon",
                focusBinding: $focusedField, focusValue: .title
            )
            .submitLabel(.next)
            .onSubmit { focusedField = .destination }
            Text("This is the big title on your trip card.")
                .helperTextStyle()
        }
    }

    private var destinationField: some View {
        FormTextField(
            label: "Destination", text: $destination, placeholder: "Lisbon, Portugal",
            focusBinding: $focusedField, focusValue: .destination
        )
        .submitLabel(.done)
        .onSubmit { focusedField = nil }
    }

    private var countryField: some View {
        // Finding 3: a searchable picker instead of a typed 2-letter code —
        // makes an invalid country unrepresentable, so the old rejection
        // hint and flag+name confirmation text are both gone. Not part of
        // the finding-1 focus chain: it's a picker sheet, not a text field.
        CountryPickerField(label: "Country", code: $countryCode)
    }

    private var datesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeading("Dates")
            LabeledDatePicker(label: "Starts", date: $startDate, displayedComponents: .date)
                .onChange(of: startDate) { _, newValue in
                    if endDate < newValue { endDate = newValue }
                }
            LabeledDatePicker(label: "Ends", date: $endDate, displayedComponents: .date, minDate: startDate)
            if !isDateRangeValid {
                Text("End date must be on or after the start date.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.rose)
                    .accessibilityAddTraits(.updatesFrequently)
                    .onAppear {
                        // Finding 4: this validation text used to render
                        // silently — nothing prompted VoiceOver to speak it,
                        // so a screen-reader user editing dates got no
                        // feedback at all. Mirrors HomeView's retry-failure
                        // caption announcement.
                        AccessibilityNotification.Announcement(
                            "End date must be on or after the start date."
                        ).post()
                    }
            }
        }
    }

    private var tripTypeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeading("Trip type")
            SegmentedControl(options: ["Family", "Friends", "Solo"], selection: tripTypeSelection)
            Text(
                "Sets this trip\u{2019}s defaults as features arrive \u{2014} friends\u{2019} trips will lean " +
                "toward splitting costs, family trips toward tracking them."
            )
            .helperTextStyle()
        }
    }

    private var coverSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeading("Cover")
            HStack(spacing: Spacing.md) {
                ForEach(Self.gradientOptions, id: \.self) { key in
                    gradientSwatch(key)
                }
                Spacer()
            }
            .padding(.vertical, Spacing.xs)
        }
    }

    private var ctaSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let guidance = Self.ctaGuidance(
                saveError: saveError?.message, title: title, countryCode: countryCode, isEditing: isEditing
            ) {
                Text(guidance.message)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(guidance.isError ? Palette.rose : Palette.slate)
                    // Finding 4: `.updatesFrequently` so VoiceOver re-reads
                    // this on change; the actual announcement post for
                    // error-toned messages is the form-level `saveError`
                    // `.onChange` above — the advisory blank-title copy is
                    // deliberately not announced (it's visible from the
                    // moment a create sheet opens; announcing there would
                    // spam every presentation).
                    .accessibilityAddTraits(.updatesFrequently)
            }
            Button {
                save()
            } label: {
                Text(isEditing ? "Save changes" : "Create trip")
                    .font(Typo.body(weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .foregroundStyle(Palette.onAmber)
                    .padding(.vertical, Spacing.md)
                    .background(Palette.amber, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                    .shadow(color: Palette.amber.opacity(0.45), radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(!isValid)
            .opacity(isValid ? 1 : 0.5)
        }
    }

    private func sectionHeading(_ text: String) -> some View {
        Text(text)
            .font(Typo.body(Typo.Size.caption, weight: .semibold))
            .foregroundStyle(Palette.slate)
    }

    /// Finding 1: the CTA-adjacent guidance text and whether it's
    /// error-toned (rose) or advisory (slate) — factored out as a `static`,
    /// like `canonicalGradientKey` below, so the save-error -> blank-title
    /// -> unacceptable-country precedence is directly testable without a
    /// view hierarchy. `ctaSection` renders exactly this. A save error takes
    /// priority (it's the freshest, most specific problem); an unacceptable
    /// country is checked last so it doesn't upstage a simpler blank-title
    /// fix, but it still always renders — including when the country field
    /// itself is scrolled off-screen (§6.6).
    static func ctaGuidance(
        saveError: String?, title: String, countryCode: String, isEditing: Bool
    ) -> (message: String, isError: Bool)? {
        if let saveError { return (saveError, true) }
        if !TripFormValidation.isTitleValid(title) {
            return ("Enter a trip name to " + (isEditing ? "save changes." : "create the trip."), false)
        }
        if !TripFormValidation.isCountryCodeAcceptable(countryCode) {
            // Finding 3 follow-up: this only fires for legacy/synced data
            // that predates the picker (new entries can't produce an
            // unacceptable code), so the copy names the picker's actual
            // actions rather than the old "fix the code" instruction, which
            // no longer describes anything the UI offers.
            return (
                "This trip\u{2019}s saved country isn\u{2019}t recognized. Tap Country and pick one \u{2014} " +
                    "or choose \u{201C}No country\u{201D} \u{2014} to " + (isEditing ? "save changes." : "create the trip."),
                true
            )
        }
        return nil
    }

    /// F8: the swatch that reads as "selected" — normalized so an unknown or
    /// legacy key (including the schema's own `"default"` alias) still maps
    /// onto a real swatch rather than leaving the row with nothing lit.
    /// Exposed as `static` for tests.
    static func canonicalGradientKey(_ key: String) -> String {
        let lowered = key.lowercased()
        return gradientOptions.contains(lowered) ? lowered : "dusk"
    }

    private func gradientSwatch(_ key: String) -> some View {
        let isSelected = Self.canonicalGradientKey(coverGradientKey) == key
        return Button {
            coverGradientKey = key
        } label: {
            CoverGradient.from(key: key)
                .frame(width: 44, height: 44)
                .clipShape(Circle())
                .overlay {
                    Circle()
                        .stroke(Palette.ink, lineWidth: isSelected ? 3 : 0)
                        .padding(-3)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(key.capitalized) gradient")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    // MARK: - Actions

    private func cancelTapped() {
        if hasChanges {
            showDiscardConfirm = true
        } else {
            dismiss()
        }
    }

    private func save() {
        guard isValid else { return }
        saveError = nil
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Whitespace-only pasted destinations shouldn't persist as visible
        // padding on the trip card or sync out over the wire.
        let trimmedDestination = destination.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStart = Calendar.current.startOfDay(for: startDate)
        let normalizedEnd = Calendar.current.startOfDay(for: endDate)

        switch mode {
        case .create:
            guard let userId = authManager.userId else {
                saveError = .signedOut
                return
            }
            let trip = Trip(
                id: UUID(),
                title: trimmedTitle,
                destination: trimmedDestination,
                countryCode: countryCode,
                startDate: normalizedStart,
                endDate: normalizedEnd,
                coverGradient: coverGradientKey,
                tripTypeRaw: tripType.rawValue,
                createdBy: userId,
                createdAt: .now,
                updatedAt: .now,
                updatedBy: nil
            )
            modelContext.insert(trip)

            // Provisional local organizer membership so role-gated UI (the
            // delete swipe) works immediately offline — the trigger-created
            // real row arrives on the next pull with the same values
            // (SYNC_DESIGN.md "Write paths").
            modelContext.insert(
                TripMember(
                    id: UUID(), tripId: trip.id, userId: userId,
                    roleRaw: TripRole.organizer.rawValue, createdAt: .now
                )
            )

            do {
                try modelContext.save()
            } catch {
                saveError = .writeFailed
                return
            }
            let dto = trip.toDTO()
            let tripId = trip.id
            Task { await syncEngine?.enqueueUpsert(table: .trips, rowId: tripId, tripId: tripId, payload: dto) }
            onSaved?(trip)

        case .edit(let trip):
            trip.title = trimmedTitle
            trip.destination = trimmedDestination
            trip.countryCode = countryCode
            trip.startDate = normalizedStart
            trip.endDate = normalizedEnd
            trip.tripType = tripType
            trip.coverGradient = coverGradientKey
            trip.updatedAt = .now
            trip.updatedBy = authManager.userId
            do {
                try modelContext.save()
            } catch {
                saveError = .writeFailed
                return
            }
            let dto = trip.toDTO()
            let tripId = trip.id
            Task { await syncEngine?.enqueueUpsert(table: .trips, rowId: tripId, tripId: tripId, payload: dto) }
            onSaved?(trip)
        }

        dismiss()
    }
}
