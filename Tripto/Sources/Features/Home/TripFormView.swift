import PhotosUI
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

    /// Feature A2's own testable source of truth for `tripTypeSection`'s
    /// segment order — `Friends` leads (see that property's doc comment).
    /// A `static let`, not an inline literal, so `TripFormViewTests` can
    /// assert the order without standing up a full view/ViewInspector.
    static let tripTypeOptions: [TripType] = [.friends, .family, .solo]

    /// E2 (docs/BACKLOG.md §E2 "Duplicate trip"): create-mode field values to
    /// seed this sheet with instead of the ordinary blank defaults — `mode`
    /// stays `.create` (a genuinely new trip row gets created), this only
    /// changes what the form opens pre-filled with. `nil` (the default)
    /// leaves `.create`'s existing blank-form behavior untouched.
    struct Prefill {
        var title: String
        var destination: String
        var countryCode: String
        var startDate: Date
        var endDate: Date
        var tripType: TripType
        var coverGradientKey: String
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// P4.4 (docs/UX_REDESIGN_ROADMAP.md): this sheet had no toast surface
    /// of its own before — needed now that "Start from a booking email
    /// instead" can chain into `AddItemSheet`, which reports back through an
    /// `onToast` closure the way every other host of that sheet already
    /// wires one.
    @State private var toast: String?

    @State private var title: String
    @State private var destination: String
    @State private var countryCode: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var tripType: TripType
    @State private var coverGradientKey: String
    /// P4.4: `true` once the user has tapped Shuffle at least once — an
    /// explicit choice, so later `countryCode` edits stop live-reseeding the
    /// cover out from under them. Same "nil/false auto, explicit override
    /// wins" shape as `AddItemSheet.arrivesTime`. Stays `false`
    /// for the whole life of an `.edit` sheet (the `.onChange` below is
    /// gated on `!isEditing` too, so an existing trip's stored cover is
    /// never silently re-seeded either way).
    @State private var hasManuallyShuffledCover = false
    /// P8b (photo trip covers): mirrors `AvatarPhotoPicker`'s own draft-
    /// until-Save shape (identical to `SettingsView.avatarPath`/
    /// `TripProfileFormSheet.avatarPath`) — the upload itself runs
    /// immediately on pick (there's no realistic way to defer the actual
    /// bytes), but the trip row's `coverImagePath` write + sync enqueue wait
    /// for this sheet's own explicit Create/Save tap, same as every other
    /// field here. Seeded from `trip.coverImagePath` in edit mode, `nil` for
    /// a brand-new create-mode trip (see `init` below).
    @State private var coverImagePath: String?
    @State private var coverPickerItem: PhotosPickerItem?
    @State private var isUploadingCoverPhoto = false
    /// P8c: draft credit pair for `coverImagePath`, kept in lockstep with it
    /// at all three write sites below (`uploadCoverPhoto` and
    /// `removeCoverPhoto` clear both; a `CoverSearchSheet` pick sets both) —
    /// by construction, whichever values live here always describe whichever
    /// photo is currently selected, so `save()` and `coverPhotoCreditLine`
    /// below can just read them directly with no extra "does this still
    /// match the photo" check. Seeded from `trip.coverCreditName`/
    /// `.coverCreditUrl` in edit mode, `nil` for a brand-new create-mode trip
    /// (mirrors `coverImagePath`'s own seeding, see `init` below).
    @State private var coverCreditName: String?
    @State private var coverCreditUrl: String?
    /// P8c: "Search photos" beside "Choose a photo" — see `CoverSearchSheet`.
    @State private var isPresentingCoverSearch = false

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
    /// Toggled right before a successful `save()` dismisses — the trigger
    /// for the `.sensoryFeedback(.success, trigger:)` below. Only reached on
    /// the success path (both failure branches `return` early), so it never
    /// fires alongside `saveError`.
    @State private var didSaveSuccessfully = false
    /// F4: gates the "Discard changes?" confirmation on cancel/swipe-dismiss.
    @State private var showDiscardConfirm = false
    /// UX audit finding 8: gates the "Delete trip" confirmation — same
    /// dialog copy Home's own swipe/context-menu delete uses.
    @State private var isPresentingDeleteConfirm = false
    /// Fix-round D4: `save()`'s create branch had no reentrancy guard, the
    /// same hole P3 fixed in `AddItemSheet.save()` (`isSaving`) — a fast
    /// double-tap (of either the "Create trip" CTA or, worse, "Start from a
    /// booking email instead") could fire a second synchronous `save()`
    /// before the first tap's insert/dismiss (or sheet-chain transition,
    /// for the booking-email path) makes the button unhittable. Same shape
    /// as `AddItemSheet.isSaving`: set synchronously as `save()`'s first
    /// statement, released on every early return, guards both branches.
    @State private var isSaving = false
    /// P4.4: set right before `save()` by `bookingEmailSecondaryAction` —
    /// `save()`'s create branch reads this to also populate
    /// `tripForBookingImport` instead of (not in addition to) its normal
    /// immediate `dismiss()`. Create-mode only; edit-mode never sets it.
    /// Fix-round D3: reset back to `false` on every one of `save()`'s
    /// create-branch early returns (`.signedOut`, `.writeFailed`) — left
    /// `true`, a signed-out or failed attempt would make a *later*, distinct
    /// plain "Create trip" tap wrongly chain into `AddItemSheet` too.
    @State private var isCreatingForBookingImport = false
    /// P4.4: non-nil right after "Start from a booking email instead"
    /// successfully creates the trip — presents `AddItemSheet` (the exact
    /// P4.2 paste-or-forward cluster) for it. `onDismiss` on that sheet is
    /// this form's own cue to finally dismiss itself (see `body`), so the
    /// user lands back on Home once they're done with the booking, not on a
    /// technically-already-saved "New trip" sheet still sitting underneath.
    @State private var tripForBookingImport: Trip?

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

    /// P4.4 (docs/UX_REDESIGN_ROADMAP.md): the cover preview's Shuffle
    /// button — sized to the 44pt floor at the base Dynamic Type size
    /// (unlike the mockup's 32pt icon button) and scaling up from there.
    @ScaledMetric(relativeTo: .body) private var shuffleButtonSide: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var shuffleIconSize: CGFloat = 16

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
        /// P8b: a brand-new create-mode trip has no photo yet (`Prefill`
        /// doesn't carry one over on duplicate either — see
        /// `TripDuplication.prefill`), so this is only ever non-nil seeded
        /// from an `.edit` trip.
        var coverImagePath: String?
    }
    private let initialValues: InitialValues

    init(
        mode: Mode, prefill: Prefill? = nil,
        onSaved: ((Trip, SaveOutcome) -> Void)? = nil, onDeleted: (() -> Void)? = nil
    ) {
        self.mode = mode
        self.onSaved = onSaved
        self.onDeleted = onDeleted
        switch mode {
        case .create:
            let seed = prefill ?? Prefill(
                title: "", destination: "", countryCode: "",
                startDate: Calendar.current.startOfDay(for: .now),
                endDate: Calendar.current.date(byAdding: .day, value: 6, to: .now) ?? .now,
                tripType: .family, coverGradientKey: "dusk"
            )
            _title = State(initialValue: seed.title)
            _destination = State(initialValue: seed.destination)
            _countryCode = State(initialValue: seed.countryCode)
            _startDate = State(initialValue: seed.startDate)
            _endDate = State(initialValue: seed.endDate)
            _tripType = State(initialValue: seed.tripType)
            _coverGradientKey = State(initialValue: seed.coverGradientKey)
            _coverImagePath = State(initialValue: nil)
            _coverCreditName = State(initialValue: nil)
            _coverCreditUrl = State(initialValue: nil)
            initialValues = InitialValues(
                title: seed.title, destination: seed.destination, countryCode: seed.countryCode,
                startDate: seed.startDate, endDate: seed.endDate,
                tripType: seed.tripType, coverGradientKey: seed.coverGradientKey, coverImagePath: nil
            )
        case .edit(let trip):
            _title = State(initialValue: trip.title)
            _destination = State(initialValue: trip.destination)
            _countryCode = State(initialValue: trip.countryCode)
            _startDate = State(initialValue: trip.startDate)
            _endDate = State(initialValue: trip.endDate)
            _tripType = State(initialValue: trip.tripType)
            _coverGradientKey = State(initialValue: trip.coverGradient)
            _coverImagePath = State(initialValue: trip.coverImagePath)
            _coverCreditName = State(initialValue: trip.coverCreditName)
            _coverCreditUrl = State(initialValue: trip.coverCreditUrl)
            initialValues = InitialValues(
                title: trip.title, destination: trip.destination, countryCode: trip.countryCode,
                startDate: trip.startDate, endDate: trip.endDate,
                tripType: trip.tripType, coverGradientKey: trip.coverGradient, coverImagePath: trip.coverImagePath
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
            // P8b: a picked-then-uploaded-but-not-yet-saved photo (or a
            // "Remove photo" tap) is discardable exactly like a typed-but-
            // not-saved title — the uploaded object itself is simply left as
            // an orphan, same v1 policy `CoverStorage`'s doc comment accepts.
            || coverImagePath != initialValues.coverImagePath
    }

    /// F6: the live snapshot `.onChange` diffs against `initialValues`
    /// (indirectly, via its own previous value) to clear a stale `saveError`
    /// the instant the user edits anything — otherwise e.g. the blank-title
    /// guidance stays stuck on screen after the title is fixed but before
    /// the CTA is tapped again.
    private var currentValues: InitialValues {
        InitialValues(
            title: title, destination: destination, countryCode: countryCode,
            startDate: startDate, endDate: endDate, tripType: tripType, coverGradientKey: coverGradientKey,
            coverImagePath: coverImagePath
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
                        bookingEmailSecondaryAction
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
        .toastOverlay($toast)
        // P4.4: "Start from a booking email instead" — `save()`'s create
        // branch populates `tripForBookingImport` instead of dismissing (see
        // that property's doc comment); `onDismiss` here is what actually
        // closes this form once the chained `AddItemSheet` is done.
        .sheet(item: $tripForBookingImport, onDismiss: { dismiss() }) { trip in
            AddItemSheet(
                tripId: trip.id, tripTitle: trip.title, editing: nil,
                tripStartDate: trip.startDate, tripCreatedBy: trip.createdBy,
                onToast: { message in toast = message }
            )
        }
        // P8c: "Search photos" — reports the picked path + Pexels credit
        // pair back into this sheet's own draft state, together; nothing is
        // written to `trip` until this sheet's own Create/Save (same
        // draft-until-Save semantics as the PhotosPicker path above).
        .sheet(isPresented: $isPresentingCoverSearch) {
            CoverSearchSheet(uploaderUserId: authManager.userId) { path, creditName, creditUrl in
                coverImagePath = path
                coverCreditName = creditName
                coverCreditUrl = creditUrl
            }
        }
        .background(
            // Finding 5: surfaces the same "Discard changes?" dialog Cancel
            // uses when a dirty form's swipe-down is blocked by
            // `.interactiveDismissDisabled` below, instead of an unexplained
            // rubber-band.
            SheetDismissAttemptObserver { showDiscardConfirm = true }
        )
        .interactiveDismissDisabled(hasChanges)
        // Trip created/saved — success haptic on the one common path both
        // `.create` and `.edit` reach at the end of `save()`.
        .sensoryFeedback(.success, trigger: didSaveSuccessfully)
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
        // P4.4: live-reseeds the cover preview as the only field that can
        // actually drive it changes — create-mode only, and only until the
        // user has taken an explicit Shuffle turn (see
        // `hasManuallyShuffledCover`'s doc comment).
        .onChange(of: countryCode) { _, newValue in
            guard !isEditing, !hasManuallyShuffledCover else { return }
            coverGradientKey = Self.seededGradientKey(countryCode: newValue, destination: destination)
        }
        // P8b: `PhotosPicker`'s own selection, not a submit button — a new
        // pick fires this the moment the system picker dismisses, same
        // `.onChange(of: pickerItem)` shape as `AvatarPhotoPicker`.
        .onChange(of: coverPickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await uploadCoverPhoto(newItem) }
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

    /// Feature A2 (adoption onboarding, light touch): `Friends` leads the
    /// segment order — previously "Family, Friends, Solo" (mirroring
    /// `TripType`'s declaration order) visually reinforced family as the
    /// "default" case even though `SegmentedControl` gives every option
    /// equal weight. No behavior change: still no type-driven logic
    /// anywhere (deferred to v2, BUILD_PLAN.md), and create mode still
    /// seeds `.family` (`Prefill`'s own default, unchanged) — this is
    /// ordering/copy only, making the choice feel deliberate rather than a
    /// silent default to skip past.
    private var tripTypeSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeading("Trip type")
            SegmentedControl(options: Self.tripTypeOptions.map { $0.rawValue.capitalized }, selection: tripTypeSelection)
        }
    }

    /// P4.4 (docs/UX_REDESIGN_ROADMAP.md): replaces the three swatch circles
    /// with one destination-seeded preview (reusing `CoverGradient` — the
    /// same three tokens `TripCard` itself renders covers from, no new color
    /// system) plus a Shuffle button. `coverGradientKey` still drives it —
    /// only this section's *control* changed, not the stored value's shape.
    ///
    /// P8b: gains a "Choose a photo"/"Remove photo" row below the gradient
    /// preview (plan D6/D1) — the two controls are independent, not a
    /// toggle: Shuffle keeps changing `coverGradientKey` even while a photo
    /// is active (it's simply not visible until the photo is removed, same
    /// "photo layers over the gradient, never replaces it" contract as
    /// every other render site).
    private var coverSection: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            sectionHeading("Cover")
            ZStack(alignment: .topTrailing) {
                CoverImage(coverGradientKey: coverGradientKey, coverImagePath: coverImagePath)
                    .frame(height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: Radii.cover, style: .continuous))
                    // Decorative — `shuffleButton`'s own label speaks for the
                    // gradient; a photo here is equally decorative (brief:
                    // "cover photo decorative — title carries meaning"), same
                    // contract as `AvatarPhotoCircle`.
                    .accessibilityHidden(true)
                shuffleButton
                    .padding(Spacing.sm)
                if isUploadingCoverPhoto {
                    ProgressView()
                        .tint(.white)
                        .padding(Spacing.sm)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .padding(.vertical, Spacing.xs)
            Text("Sets the cover on your trip card. Tap shuffle for a different one, or choose your own photo below.")
                .helperTextStyle()
            coverPhotoPickerRow
            coverPhotoCreditLine
        }
    }

    /// "Choose a photo"/"Change photo" + "Search photos" (P8c) + (once set)
    /// "Remove photo" — same pill/44pt-target styling as `AvatarPhotoPicker`'s
    /// identical pair, not reused directly: that component is a
    /// fixed-diameter CIRCLE preview (one profile-photo shape everywhere),
    /// while this section's own preview is the wide gradient card above:
    /// `AvatarPhotoPicker`'s actual preview half doesn't fit here, only its
    /// button recipe does.
    ///
    /// P8c: `WrapLayout` instead of a plain `HStack` — a third pill now has
    /// to fit alongside "Choose/Change a photo" and (once set) "Remove
    /// photo", which would overflow an `HStack` at larger Dynamic Type sizes
    /// (`WrapLayout`'s own established use: `TimelineCardRow`'s
    /// assignees+tags row hit the identical problem first). No trailing
    /// `Spacer` — `WrapLayout` already left-aligns and wraps on its own.
    private var coverPhotoPickerRow: some View {
        WrapLayout(horizontalSpacing: Spacing.md, verticalSpacing: Spacing.sm) {
            PhotosPicker(selection: $coverPickerItem, matching: .images) {
                Text(coverImagePath == nil ? "Choose a photo" : "Change photo")
                    .font(Typo.body(Typo.Size.caption, weight: .bold))
                    .foregroundStyle(Palette.onAmber)
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.md)
                    // Fix-round (client-reported bug): the visual pill
                    // rendered bare-text small (~20pt) despite a correct
                    // 44pt hit band — `.background` used to sit BEFORE
                    // `.frame(minHeight:)`, so the painted capsule sized
                    // itself to the unpadded text, floating small inside the
                    // invisible 44pt frame around it. `.frame(minHeight:)`
                    // before `.contentShape` (still) is what makes the whole
                    // frame tappable; `.background` LAST is what makes the
                    // capsule actually fill it — same order as every other
                    // 44pt pill CTA already shipped in this codebase
                    // (`HomeView`, `BookingsTabView`, `PackingListView`,
                    // `ItineraryTabView`, `TripView`, `BookingDetailView`).
                    .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor
                    .contentShape(Capsule())
                    .background(Palette.amber, in: Capsule())
            }
            .disabled(isUploadingCoverPhoto)

            searchPhotosButton

            if coverImagePath != nil {
                Button(role: .destructive) {
                    removeCoverPhoto()
                } label: {
                    Text("Remove photo")
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(Palette.rose)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .disabled(isUploadingCoverPhoto)
            }
        }
    }

    /// P8c: opens `CoverSearchSheet` — the second, independent entry point
    /// into the same draft `coverImagePath` `coverPhotoPickerRow`'s
    /// `PhotosPicker` already writes. Neutral secondary pill (`Palette.mist`
    /// fill / `Palette.ink` text — the app's own default running-text-on-
    /// surface pairing, already relied on everywhere, not a new contrast to
    /// justify) so it doesn't compete with the amber CTA weight of
    /// "Choose/Change a photo".
    private var searchPhotosButton: some View {
        Button {
            isPresentingCoverSearch = true
        } label: {
            Text("Search photos")
                .font(Typo.body(Typo.Size.caption, weight: .bold))
                .foregroundStyle(Palette.ink)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.md)
                // Fix-round: see `coverPhotoPickerRow`'s identical comment —
                // same missing-vertical-padding + background-before-frame bug.
                .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor
                .contentShape(Capsule())
                .background(Palette.mist, in: Capsule())
        }
        .disabled(isUploadingCoverPhoto)
    }

    /// P8c: now backed by real draft state (`coverCreditName`/
    /// `coverCreditUrl` above) instead of P8b's read-only mirror of the
    /// stored trip — shows whenever THIS session's draft credit is set,
    /// whether that's a freshly-picked `CoverSearchSheet` photo (immediate
    /// feedback before Save) or an unchanged existing one from `.edit` mode.
    /// The old P8b gate (`coverImagePath == initialValues.coverImagePath`)
    /// is gone: it only existed because that phase's credit had no draft of
    /// its own, so it had to hide the instant the live picker diverged from
    /// what the sheet opened with. Now `coverCreditName`/`coverCreditUrl`
    /// are kept in lockstep with `coverImagePath` at all three write sites
    /// (`uploadCoverPhoto`/`removeCoverPhoto` clear both; a
    /// `CoverSearchSheet` pick sets both) — by construction, whichever
    /// values live here always describe whichever photo is currently
    /// selected, so no extra "does this still match" check is needed here.
    ///
    /// Legibility fix (P8b inherited nit, DECISIONS.md 2026-07-16): was
    /// `Typo.body(10.5)` + `.underline()` only — below the ~12pt bar, and
    /// relying on underline as the sole "this is a link" affordance. Now the
    /// same external-link recipe as `PrivacySummaryView`'s "Read the full
    /// privacy policy" (`Palette.amberInk` — already measured ~5.0:1 on
    /// `Palette.paper` in light mode, ~7.7:1 in dark, per that token's own
    /// doc comment — plus an `arrow.up.forward.square` glyph) at
    /// `Typo.Size.caption` (12.5pt, clears the bar). `.fixedSize` so the
    /// text wraps rather than getting compressed by the fixed-size glyph
    /// sharing the `HStack` (CONTRACTS: "credit line wraps").
    @ViewBuilder
    private var coverPhotoCreditLine: some View {
        if let presentation = Self.coverCreditPresentation(creditName: coverCreditName, creditUrl: coverCreditUrl) {
            Link(destination: presentation.url) {
                HStack(spacing: Spacing.xs) {
                    Text("Photo by \(presentation.name) on Pexels")
                        .fixedSize(horizontal: false, vertical: true)
                    Image(systemName: "arrow.up.forward.square")
                        .accessibilityHidden(true)
                }
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.amberInk)
                .frame(minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
        }
    }

    /// Pure presentation gate for `coverPhotoCreditLine`, mirroring
    /// `ctaGuidance`'s "static, testable, exposed for exactly this" shape —
    /// both fields must be non-nil AND the URL string must actually parse;
    /// any single failure hides the line entirely rather than rendering a
    /// half-credited or dead-link row.
    static func coverCreditPresentation(creditName: String?, creditUrl: String?) -> (name: String, url: URL)? {
        guard let creditName, let creditUrl, let url = URL(string: creditUrl) else { return nil }
        return (creditName, url)
    }

    private func uploadCoverPhoto(_ item: PhotosPickerItem) async {
        guard let userId = authManager.userId else {
            toast = "Sign in first, then try again."
            return
        }
        isUploadingCoverPhoto = true
        defer {
            isUploadingCoverPhoto = false
            coverPickerItem = nil // lets re-picking the same asset re-trigger `.onChange`
        }
        do {
            // Never `type: Image.self` — see `AvatarPhotoPicker.upload`'s
            // identical doc comment: that would skip straight past
            // `ImageProcessing`'s own downsample step.
            guard let rawData = try await item.loadTransferable(type: Data.self) else {
                toast = "Couldn\u{2019}t read that photo. Try another."
                return
            }
            let jpeg = try await ImageProcessing.downsampledJPEG(rawData, maxPixelSize: ImageProcessing.coverMaxPixelSize)
            // Atomic (brief): `coverImagePath` only ever changes on a
            // SUCCESSFUL upload — a thrown error below leaves it (and thus
            // whatever was rendering, an existing photo or the bare
            // gradient) untouched, and this `do` falls straight to the
            // `catch`'s toast.
            let path = try await CoverStorage.upload(jpeg, for: userId)
            coverImagePath = path
            // P8c: an own-photo pick has no Pexels credit — clear any
            // existing one (e.g. replacing a `CoverSearchSheet` pick from
            // earlier this same session) together with the new path, never
            // leaving a credit pointing at a photo that's no longer selected.
            coverCreditName = nil
            coverCreditUrl = nil
        } catch {
            toast = PhotoUploadFeedback.message(for: error)
        }
    }

    /// P8c: "Remove photo" — same "clear the credit together with the path"
    /// rule as `uploadCoverPhoto`'s success case above, factored out since
    /// both `coverPhotoPickerRow`'s button and (indirectly) tests reference
    /// this exact triple.
    private func removeCoverPhoto() {
        coverImagePath = nil
        coverCreditName = nil
        coverCreditUrl = nil
    }

    private var shuffleButton: some View {
        Button {
            withAnimation(Motion.m(.snappy, reduceMotion: reduceMotion)) {
                hasManuallyShuffledCover = true
                // P6.5: real entropy at the call site — `nextShuffledGradientKey`
                // itself stays a deterministic, testable function of it (see
                // that method's own doc comment).
                coverGradientKey = Self.nextShuffledGradientKey(current: coverGradientKey, seed: .random(in: .min ... .max))
            }
        } label: {
            Image(systemName: "shuffle")
                .font(.system(size: shuffleIconSize, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: shuffleButtonSide, height: shuffleButtonSide)
                // `Palette.coverPillFill` — the same black-38% fill
                // `TripCard`'s own glass pills use over a cover gradient,
                // already measured ~5.5:1–16:1 for white across all three
                // gradients' lightest stops (`PaletteExtras.coverPillFill`'s
                // doc comment), reused rather than a new opacity value.
                .background(Palette.coverPillFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Shuffle cover")
        .accessibilityHint("Picks a different cover gradient")
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
                    // Bug fix: `onAmber` is a fixed near-black (`#241505`,
                    // deliberately non-adaptive so it stays readable against
                    // `amber`, which is likewise fixed — see its doc
                    // comment). Left hardcoded here while the background
                    // below swaps to `mist` (which IS dynamic) for the
                    // disabled state, near-black-on-dark-navy in dark mode
                    // made this button's disabled label unreadable.
                    .foregroundStyle(canSubmit ? Palette.onAmber : Palette.slate)
                    .padding(.vertical, Spacing.md)
                    .background(
                        canSubmit ? Palette.amber : Palette.mist,
                        in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    )
                    // UX audit cycle 2 finding 5: the amber glow only reads
                    // as "tappable" when the CTA actually is — a disabled
                    // button that still glows contradicts the adjacent "not
                    // yet" guidance above it.
                    .shadow(color: canSubmit ? Palette.amberGlow.opacity(0.45) : .clear, radius: 10, y: 5)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit || isSaving)
        }
    }

    /// P4.4 (docs/UX_REDESIGN_ROADMAP.md): create-mode only — an edit sheet's
    /// trip already exists, so there's nothing left to "start from". Reuses
    /// (doesn't duplicate) the exact P4.2 paste-or-forward surface: tapping
    /// this runs the ordinary, validation-gated `save()` (same `canSubmit`
    /// gate as "Create trip") with `isCreatingForBookingImport` set, which
    /// redirects `save()`'s usual immediate `dismiss()` into presenting
    /// `AddItemSheet` for the just-created trip instead (see
    /// `tripForBookingImport`'s doc comment).
    ///
    /// P7c (award audit #5): was a dashed `Palette.mist` outline with no
    /// fill — the same "empty placeholder slot" recipe `ItineraryTabView
    /// .daySkeleton`/`EmptyStateArt` use for a not-yet-filled spot, not an
    /// always-real, always-tappable secondary action. Enabled, it barely
    /// read as different from the primary "Create trip" CTA's own disabled
    /// state right above it (both landed on a flat, low-contrast surface).
    /// Now uses the same warm `Palette.amberSoft` secondary-CTA fill
    /// `AddItemSheet`'s "Save & add the return leg" button already
    /// establishes (foreground still dims to `Palette.slate` when
    /// `!canSubmit`, unchanged) — a distinct, always-warm secondary tier,
    /// never mistakable for the primary's own on/off states.
    @ViewBuilder
    private var bookingEmailSecondaryAction: some View {
        if !isEditing {
            Button {
                isCreatingForBookingImport = true
                save()
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "sparkles")
                        .accessibilityHidden(true)
                    Text("Start from a booking email instead")
                        .font(Typo.body(weight: .semibold))
                }
                .foregroundStyle(canSubmit ? Palette.ink : Palette.slate)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Spacing.md)
                .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit || isSaving)
            .padding(.top, Spacing.xs)
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
    ///
    /// P6.5: a valid generated key (`CoverGradientGenerator.decode` can
    /// parse it) is preserved as itself rather than folded into `"dusk"` —
    /// it's a genuine, distinct cover, not a legacy/unknown one, and
    /// `isCoverGradientChanged` below needs two different generated covers
    /// to keep reading as a change. Only a key that's neither a curated
    /// name nor valid generator syntax still falls back to `"dusk"`.
    static func canonicalGradientKey(_ key: String) -> String {
        let lowered = key.lowercased()
        if gradientOptions.contains(lowered) { return lowered }
        return CoverGradientGenerator.parsedHues(lowered) != nil ? lowered : "dusk"
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

    /// P4.4: the cover preview's destination-seeded default. Deliberately
    /// NOT `String.hashValue`/`Hashable.hash(into:)` — Swift's `Hasher` is
    /// randomly re-seeded every process launch (hash-flooding protection),
    /// so the same destination would render a different cover every cold
    /// start. This is a plain deterministic byte-sum checksum instead,
    /// indexed into the same three keys `gradientOptions` already exposes —
    /// no new color system. Blank input (a brand-new, untouched create
    /// sheet — `destination` has no visible field to type into any more,
    /// see the `FocusField` doc comment above, but a `Prefill`/duplicated
    /// trip can still carry one) keeps today's "dusk" default.
    static func seededGradientKey(countryCode: String, destination: String) -> String {
        let seed = (countryCode + destination).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !seed.isEmpty else { return "dusk" }
        let checksum = seed.utf8.reduce(0) { $0 &+ Int($1) }
        return gradientOptions[checksum % gradientOptions.count]
    }

    /// The Shuffle button's re-roll — cycles to the next of the three
    /// options rather than a true random pick, so it's always visibly
    /// different from the current one (a random pick can repeat the same
    /// gradient back to back, reading as "the button did nothing") and stays
    /// deterministic for tests. `canonicalGradientKey` first, so shuffling
    /// from an unknown/legacy key (e.g. `"default"`) still steps from a real
    /// position in `gradientOptions`.
    static func shuffledGradientKey(current: String) -> String {
        let currentIndex = gradientOptions.firstIndex(of: canonicalGradientKey(current)) ?? 0
        let nextIndex = (currentIndex + 1) % gradientOptions.count
        return gradientOptions[nextIndex]
    }

    /// P6.5: what the Shuffle button actually calls now — mixes fresh
    /// `CoverGradientGenerator` rolls in with the three curated classics
    /// (`shuffledGradientKey`, unchanged, still exactly the old cycling
    /// behavior and still covered by its own tests) rather than replacing
    /// them, so a user after one of the three recognizable looks can still
    /// reach it by shuffling. `seed` is real entropy at the call site; one
    /// in four rolls (`seed % 4 == 0`) steps to the next curated classic,
    /// the other three generate a brand-new random gradient — this
    /// function itself stays a deterministic, testable function of `seed`.
    static func nextShuffledGradientKey(current: String, seed: UInt64) -> String {
        guard seed.isMultiple(of: 4) else {
            return CoverGradientGenerator.generate(seed: seed)
        }
        return shuffledGradientKey(current: current)
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
        guard isValid, !isSaving else { return }
        isSaving = true
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
                isSaving = false
                isCreatingForBookingImport = false
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
                updatedBy: nil,
                // P8b: atomic by construction — `coverImagePath` only ever
                // holds a path once `uploadCoverPhoto`/a `CoverSearchSheet`
                // pick has already awaited a SUCCESSFUL upload; a brand-new
                // trip with no photo picked keeps this `nil`, same as before
                // P8b. P8c: `coverCreditName`/`coverCreditUrl` carry over
                // too — a trip CAN already have a Pexels credit the moment
                // it's first created, if that's how its cover was picked.
                coverImagePath: coverImagePath,
                coverCreditName: coverCreditName,
                coverCreditUrl: coverCreditUrl
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
                isSaving = false
                isCreatingForBookingImport = false
                return
            }
            let dto = trip.toDTO()
            let tripId = trip.id
            Task { await syncEngine?.enqueueUpsert(table: .trips, rowId: tripId, tripId: tripId, payload: dto) }
            onSaved?(trip, .saved)
            // P4.4: redirects the trailing `dismiss()` below into presenting
            // `AddItemSheet` for this trip instead — see
            // `tripForBookingImport`'s doc comment.
            if isCreatingForBookingImport {
                tripForBookingImport = trip
            }

        case .edit(let trip):
            trip.title = trimmedTitle
            trip.destination = trimmedDestination
            trip.countryCode = countryCode
            trip.startDate = normalizedStart
            trip.endDate = normalizedEnd
            trip.tripType = tripType
            trip.coverGradient = coverGradientKey
            trip.coverImagePath = coverImagePath
            // P8c: a plain paired write, no conditional needed — a credit
            // names one specific photo, and `coverCreditName`/
            // `coverCreditUrl` are now real draft state kept in lockstep
            // with `coverImagePath` at every write site (own-photo pick and
            // Remove clear both; a `CoverSearchSheet` pick sets both), so
            // whichever values are in the draft already correctly describe
            // whichever photo is currently selected — including the "no
            // change this session" case, where both drafts still equal
            // whatever `initialValues` captured. (P8b's version of this
            // guarded with `if coverImagePath != initialValues.coverImagePath
            // { clear }`, back when the credit had no draft of its own to
            // stay in sync — that guard would now wrongly null out a
            // freshly-picked Pexels credit on the very save meant to
            // persist it.)
            trip.coverCreditName = coverCreditName
            trip.coverCreditUrl = coverCreditUrl
            trip.updatedAt = .now
            trip.updatedBy = authManager.userId
            do {
                try modelContext.save()
            } catch {
                saveError = .writeFailed
                isSaving = false
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

        didSaveSuccessfully.toggle()
        // P4.4: `tripForBookingImport` only ever gets set on the
        // `.create`+`isCreatingForBookingImport` path above — every other
        // save (including every `.edit`) dismisses immediately, unchanged.
        if tripForBookingImport == nil {
            dismiss()
        } else {
            // The chained `AddItemSheet` covers this view instead of
            // dismissing it (`body`'s `.sheet(item: $tripForBookingImport)`)
            // — release the reentrancy guard same as `AddItemSheet.save
            // (andDismiss: false)` does, so this instance stays consistent
            // rather than permanently "mid-save" underneath the child sheet.
            isSaving = false
        }
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
