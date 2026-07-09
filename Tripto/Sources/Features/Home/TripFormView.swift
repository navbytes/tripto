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

    /// UX audit finding 5: an edit save while signed out still writes
    /// locally (the trip already exists — blocking here the way create-mode
    /// does would be worse), but the immediate toast needs to say so rather
    /// than claiming an unqualified "saved" the sync-issue banner then has
    /// to silently contradict. Create-mode always reports `.saved` since it
    /// hard-stops on a nil `userId` before ever reaching a save.
    enum SaveOutcome {
        case saved
        case savedLocallyWhileSignedOut
    }

    /// Fires after a successful save, before `dismiss()` — `HomeView`'s
    /// hook (UX audit finding 2) to switch to whichever tab the saved trip
    /// actually files under, so a trip created/edited into the other tab
    /// doesn't silently vanish. `nil` by default so callers that don't need
    /// this hook compile unchanged.
    var onSaved: ((Trip, SaveOutcome) -> Void)?

    /// UX audit finding 8: fires after a confirmed delete, before
    /// `dismiss()` — lets a caller presenting this sheet from *inside* the
    /// trip (`TripView`'s hero pencil) pop back to Home too, instead of
    /// leaving the traveler on a screen for a trip that no longer exists.
    /// `nil` for callers (Home's own edit sheet) that don't need the extra
    /// hop: their trip list already reflects the deletion via `@Query`.
    var onDeleted: (() -> Void)?

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
    /// UX audit finding 8: gates the "Delete trip" confirmation — same
    /// dialog copy Home's own swipe/context-menu delete uses.
    @State private var isPresentingDeleteConfirm = false

    /// UX audit finding 4: set whenever `startDate`'s `.onChange` silently
    /// snapped `endDate` forward to keep the range valid, so a caption can
    /// surface what just happened instead of leaving the user to notice
    /// (or not) that Ends quietly moved. Cleared the moment the user takes
    /// `endDate` back over themselves.
    @State private var endDateAutoAdjusted = false
    /// Distinguishes the snap's own programmatic write to `endDate` (in
    /// `startDate`'s `.onChange`) from a user-driven edit of `endDate` — the
    /// two land on the same `.onChange(of: endDate)`, and only the second
    /// should clear `endDateAutoAdjusted`.
    @State private var suppressEndDateResetOnce = false

    /// UX audit finding 5: lets the Trip name field's own return key dismiss
    /// the keyboard directly, rather than requiring the keyboard's dismiss
    /// key or a tap elsewhere. Country dropped out of the focus chain when
    /// it became a picker (finding 3) rather than a typed field, and the
    /// free-text Destination field it used to chain into is gone (UX audit
    /// cycle 2 finding 1) — Title is now the only focusable field left.
    private enum FocusField {
        case title
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

    init(mode: Mode, onSaved: ((Trip, SaveOutcome) -> Void)? = nil, onDeleted: (() -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
        self.onDeleted = onDeleted
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

    /// UX audit cycle 2 finding 2: create-mode's save already hard-stops on a
    /// nil `userId` (`save()`'s `.signedOut` guard below), but that dead end
    /// used to only surface after the user filled the whole form and tapped
    /// Create. Checking it up front — the moment the sheet opens, before
    /// anything's typed — lets the CTA guidance and disabled state name the
    /// real blocker immediately instead of after the fact. Edit-mode is
    /// unaffected: an edit save while signed out still writes locally (see
    /// `SaveOutcome.savedLocallyWhileSignedOut`), so it isn't blocked here.
    private var isSignedOutOnCreate: Bool {
        !isEditing && authManager.userId == nil
    }

    /// Whether the CTA should actually be tappable — valid fields alone
    /// aren't enough on a signed-out create sheet, since `save()` would just
    /// hard-stop on the nil `userId` anyway.
    private var canSubmit: Bool {
        isValid && !isSignedOutOnCreate
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
            || Self.isCoverGradientChanged(current: coverGradientKey, initial: initialValues.coverGradientKey)
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
                        countryField
                        datesSection
                        tripTypeSection
                        coverSection
                        ctaSection
                        // UX audit finding 8: edit-mode only, see
                        // `deleteSection`'s doc comment.
                        if isEditing {
                            deleteSection
                        }
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
        // UX audit finding 8: same "Delete trip" copy Home's own swipe/
        // context-menu delete uses (`HomeView.swift`), so the two entry
        // points read as one action, not two.
        .confirmationDialog("Delete trip", isPresented: $isPresentingDeleteConfirm, titleVisibility: .visible) {
            Button("Delete trip", role: .destructive) { deleteTrip() }
            Button("Cancel", role: .cancel) {}
        } message: {
            // `initialValues.title` (the trip's actual stored title), not
            // the live `title` field — an in-progress unsaved rename
            // shouldn't be quoted back as if it were already saved.
            Text("This removes \u{201C}\(initialValues.title)\u{201D} and everything in it for everyone on the trip.")
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
            // 1) so a user who's already tapped into Title within the
            // delay isn't yanked back to it a second time.
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
            .submitLabel(.done)
            .onSubmit { focusedField = nil }
            Text("This is the big title on your trip card.")
                .helperTextStyle()
        }
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
                    if endDate < newValue {
                        // Finding 4: the snap below is about to fire
                        // `endDate`'s own `.onChange` — set the guard first
                        // so that handler knows this write is programmatic,
                        // not the user editing Ends themselves.
                        suppressEndDateResetOnce = true
                        endDate = newValue
                        endDateAutoAdjusted = true
                        AccessibilityNotification.Announcement(
                            "Ends moved to \(endDate.formatted(date: .abbreviated, time: .omitted)) " +
                                "to match the new start date."
                        ).post()
                    } else {
                        endDateAutoAdjusted = false
                    }
                }
            LabeledDatePicker(label: "Ends", date: $endDate, displayedComponents: .date, minDate: startDate)
                .onChange(of: endDate) { _, _ in
                    if suppressEndDateResetOnce {
                        suppressEndDateResetOnce = false
                    } else {
                        // The user moved Ends themselves — the earlier snap,
                        // if any, no longer describes the current state.
                        endDateAutoAdjusted = false
                    }
                }
            if endDateAutoAdjusted {
                // Advisory tone (slate, not rose) — nothing is wrong here,
                // Ends just moved to stay valid.
                Text(
                    "Ends moved to \(endDate.formatted(date: .abbreviated, time: .omitted)) " +
                        "to match the new start date."
                )
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)
                .accessibilityAddTraits(.updatesFrequently)
            }
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
            // UX audit cycle 2 finding 3: no longer names "splitting costs"/
            // "tracking them" — both are v2-scope features (BUILD_PLAN §5.5)
            // that don't exist yet, and the old copy also didn't describe
            // Solo. This wording is feature-agnostic and applies to all
            // three options.
            Text("A hint about who\u{2019}s traveling \u{2014} Tripto tailors its defaults as more features arrive.")
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
            // UX audit cycle 2 finding 4: every other section already has a
            // helper line under its control — Cover was the one section
            // missing it.
            Text("Sets the cover on your trip card.")
                .helperTextStyle()
        }
    }

    private var ctaSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if let guidance = Self.ctaGuidance(
                saveError: saveError?.message, title: title, countryCode: countryCode, isEditing: isEditing,
                isSignedOutOnCreate: isSignedOutOnCreate
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
                    .background(
                        canSubmit ? Palette.amber : Palette.mist,
                        in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    )
                    // UX audit cycle 2 finding 5: the amber glow only reads
                    // as "tappable" when the CTA actually is — a disabled
                    // button that still glows contradicts the adjacent "not
                    // yet" guidance above it.
                    .shadow(color: canSubmit ? Palette.amber.opacity(0.45) : .clear, radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .opacity(canSubmit ? 1 : 0.5)
        }
    }

    /// UX audit finding 8: an organizer could edit a trip from inside it
    /// (this sheet, via the hero pencil) but could only ever delete it by
    /// backing out to Home first — full lifecycle control (edit *and*
    /// delete) belongs together, the way Booking detail already pairs them.
    /// Edit-mode only: a trip being created has nothing to delete yet.
    private var deleteSection: some View {
        Button(role: .destructive) {
            isPresentingDeleteConfirm = true
        } label: {
            Text("Delete trip")
                .font(Typo.body(weight: .semibold))
                .foregroundStyle(Palette.rose)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
        }
        .buttonStyle(.plain)
        .padding(.top, Spacing.xs)
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
    ///
    /// UX audit cycle 2 finding 2: `isSignedOutOnCreate` is checked first,
    /// ahead of even `saveError` — a signed-out create sheet can't be saved
    /// no matter what's typed, so that's the freshest, most specific problem
    /// the moment the sheet opens, before a save has even been attempted.
    static func ctaGuidance(
        saveError: String?, title: String, countryCode: String, isEditing: Bool, isSignedOutOnCreate: Bool
    ) -> (message: String, isError: Bool)? {
        if isSignedOutOnCreate {
            return ("You\u{2019}re signed out. Sign back in to create a trip.", true)
        }
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

    /// UX audit finding 6: `hasChanges` should compare gradients by what
    /// they *render as*, not their raw stored strings — otherwise a trip
    /// stored as the legacy `"default"` key (which renders Dusk-lit, same as
    /// `"dusk"`) reads as dirty the instant the sheet opens, and tapping the
    /// already-lit Dusk swatch (which writes literal `"dusk"`) spuriously
    /// triggers "Discard changes?" on Cancel/swipe-down. Accepted edge: two
    /// distinct unknown legacy keys (e.g. `"default"` and `"sunset"`) both
    /// canonicalize to `"dusk"`, so re-tapping Dusk on a `"sunset"` trip also
    /// reads as clean — consistent with the swatch already rendering as
    /// selected. Stored data is untouched by this; a save for other reasons
    /// simply writes `"dusk"` over the legacy key, which is a harmless,
    /// schema-valid normalization.
    static func isCoverGradientChanged(current: String, initial: String) -> Bool {
        canonicalGradientKey(current) != canonicalGradientKey(initial)
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
            onSaved?(trip, .saved)

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
            // Finding 5: the write above already happened (local-first edit
            // — blocking here the way create-mode does would be worse, the
            // trip already exists), but a signed-out save still needs an
            // honest toast rather than an unqualified "saved" that the
            // sync-issue banner then has to silently contradict.
            let outcome: SaveOutcome = authManager.userId == nil ? .savedLocallyWhileSignedOut : .saved
            onSaved?(trip, outcome)
        }

        dismiss()
    }

    /// UX audit finding 8: local delete + enqueue, same shape as
    /// `HomeView.delete(_:)`. Deliberately doesn't re-derive that function's
    /// local member/profile cascade here — this sheet doesn't hold those
    /// `@Query`s, and `SyncEngine.pullHome()`'s `store.pruneOrphans()`
    /// (SYNC_DESIGN.md "Write paths") is already the documented safety net
    /// for exactly this case: any local rows this trip leaves behind get
    /// swept on the next home pull, the same as if the trip had been deleted
    /// server-side by someone else.
    private func deleteTrip() {
        guard case .edit(let trip) = mode else { return }
        let tripId = trip.id
        modelContext.delete(trip)
        try? modelContext.save()
        Task { await syncEngine?.enqueueDelete(table: .trips, rowId: tripId, tripId: tripId) }
        onDeleted?()
        dismiss()
    }
}
