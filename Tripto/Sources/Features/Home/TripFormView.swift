import SwiftData
import SwiftUI

/// Create/edit sheet for a trip (BUILD_PLAN.md §4.1). Every save is a plain
/// SwiftData write on the main context followed by `SyncEngine.enqueue` —
/// the same "instant UI, queued sync" flow every mutation in the app uses.
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

    /// The three tokens `CoverGradient` defines (`"default"` is just an
    /// alias for `dusk`, not a fourth option) — `dusk` is pre-selected for
    /// new trips, matching the schema's own column default.
    private static let gradientOptions = ["dusk", "plum", "moss"]

    init(mode: Mode, onSaved: ((Trip) -> Void)? = nil) {
        self.mode = mode
        self.onSaved = onSaved
        switch mode {
        case .create:
            _title = State(initialValue: "")
            _destination = State(initialValue: "")
            _countryCode = State(initialValue: "")
            _startDate = State(initialValue: Calendar.current.startOfDay(for: .now))
            _endDate = State(initialValue: Calendar.current.date(byAdding: .day, value: 6, to: .now) ?? .now)
            _tripType = State(initialValue: .family)
            _coverGradientKey = State(initialValue: "dusk")
        case .edit(let trip):
            _title = State(initialValue: trip.title)
            _destination = State(initialValue: trip.destination)
            _countryCode = State(initialValue: trip.countryCode)
            _startDate = State(initialValue: trip.startDate)
            _endDate = State(initialValue: trip.endDate)
            _tripType = State(initialValue: trip.tripType)
            _coverGradientKey = State(initialValue: trip.coverGradient)
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
        TripFormValidation.isValid(title: title, startDate: startDate, endDate: endDate)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Trip") {
                    TextField("Title", text: $title)
                    TextField("Destination", text: $destination)
                    TextField("Country code", text: $countryCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: countryCode) { _, newValue in
                            let filtered = String(newValue.uppercased().prefix(2))
                            if filtered != countryCode { countryCode = filtered }
                        }
                }

                Section("Dates") {
                    DatePicker("Start", selection: $startDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                    DatePicker("End", selection: $endDate, displayedComponents: .date)
                        .datePickerStyle(.compact)
                    if !isDateRangeValid {
                        Text("End date must be on or after the start date.")
                            .font(Typo.body(Typo.Size.caption))
                            .foregroundStyle(.red)
                    }
                }

                Section("Trip type") {
                    Picker("Trip type", selection: $tripType) {
                        ForEach(TripType.allCases, id: \.self) { type in
                            Text(type.rawValue.capitalized).tag(type)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("Cover") {
                    HStack(spacing: Spacing.md) {
                        ForEach(Self.gradientOptions, id: \.self) { key in
                            gradientSwatch(key)
                        }
                        Spacer()
                    }
                    .padding(.vertical, Spacing.xs)
                }

                Section {
                    Button {
                        save()
                    } label: {
                        Text(isEditing ? "Save changes" : "Create trip")
                            .font(Typo.body(weight: .semibold))
                            .frame(maxWidth: .infinity)
                    }
                    .disabled(!isValid)
                }
            }
            .navigationTitle(isEditing ? "Edit trip" : "Plan a new trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func gradientSwatch(_ key: String) -> some View {
        let isSelected = coverGradientKey == key
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

    private func save() {
        guard isValid else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedStart = Calendar.current.startOfDay(for: startDate)
        let normalizedEnd = Calendar.current.startOfDay(for: endDate)

        switch mode {
        case .create:
            guard let userId = authManager.userId else { return }
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

            try? modelContext.save()
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
            try? modelContext.save()
            let dto = trip.toDTO()
            let tripId = trip.id
            Task { await syncEngine?.enqueueUpsert(table: .trips, rowId: tripId, tripId: tripId, payload: dto) }
            onSaved?(trip)
        }

        dismiss()
    }
}
