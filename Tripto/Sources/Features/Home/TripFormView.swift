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
    /// enqueued or dismissed, and the user can retry.
    @State private var saveError: String?
    /// F4: gates the "Discard changes?" confirmation on cancel/swipe-dismiss.
    @State private var showDiscardConfirm = false

    /// The three tokens `CoverGradient` defines (`"default"` is just an
    /// alias for `dusk`, not a fourth option) — `dusk` is pre-selected for
    /// new trips, matching the schema's own column default.
    private static let gradientOptions = ["dusk", "plum", "moss"]

    /// F4: the field values this sheet opened with, so `hasChanges` can tell
    /// an untouched form from a dirty one.
    private struct InitialValues {
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
        .interactiveDismissDisabled(hasChanges)
        .confirmationDialog("Discard changes?", isPresented: $showDiscardConfirm, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
            Button("Keep editing", role: .cancel) {}
        }
    }

    // MARK: - Fields

    private var tripNameField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            FormTextField(label: "Trip name", text: $title, placeholder: "Lisbon")
            Text("This is the big title on your trip card.")
                .font(Typo.body(9.5))
                .foregroundStyle(Palette.slate.opacity(0.8))
        }
    }

    private var destinationField: some View {
        FormTextField(label: "Destination", text: $destination, placeholder: "Lisbon, Portugal")
    }

    private var countryField: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            FormTextField(
                label: "Country", text: $countryCode, placeholder: "2-letter code, e.g. PT",
                autocapitalization: .characters
            )
            .onChange(of: countryCode) { _, newValue in
                let filtered = String(newValue.uppercased().prefix(2))
                if filtered != countryCode { countryCode = filtered }
            }
            if let countryName = TripFormValidation.countryName(forCode: countryCode) {
                Text(countryName)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            } else if countryCode.count == 2 {
                Text(
                    "\u{2018}\(countryCode)\u{2019} isn\u{2019}t a country code Tripto recognizes " +
                    "\u{2014} use a 2-letter code like PT for Portugal."
                )
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(.red)
            }
        }
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
                    .foregroundStyle(.red)
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
            .font(Typo.body(9.5))
            .foregroundStyle(Palette.slate.opacity(0.8))
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
            if let saveError {
                Text(saveError)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(.red)
            } else if !TripFormValidation.isTitleValid(title) {
                Text("Enter a trip name to " + (isEditing ? "save changes." : "create the trip."))
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
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
        let normalizedStart = Calendar.current.startOfDay(for: startDate)
        let normalizedEnd = Calendar.current.startOfDay(for: endDate)

        switch mode {
        case .create:
            guard let userId = authManager.userId else {
                saveError = "You\u{2019}re signed out \u{2014} sign in again to create this trip."
                return
            }
            let trip = Trip(
                id: UUID(),
                title: trimmedTitle,
                destination: destination,
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
                saveError = "Couldn\u{2019}t save the trip. Try again."
                return
            }
            let dto = trip.toDTO()
            let tripId = trip.id
            Task { await syncEngine?.enqueueUpsert(table: .trips, rowId: tripId, tripId: tripId, payload: dto) }
            onSaved?(trip)

        case .edit(let trip):
            trip.title = trimmedTitle
            trip.destination = destination
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
                saveError = "Couldn\u{2019}t save the trip. Try again."
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
