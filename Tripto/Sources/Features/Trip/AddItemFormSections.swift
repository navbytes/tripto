import SwiftUI

/// The four contextual field groups (BUILD_PLAN.md §4.3) plus the small
/// shared row components they're built from. Split from `AddItemSheet.swift`
/// purely to keep each file a readable size — everything here operates on
/// that struct's own `@State`, so it's one type across two files, not a
/// separate component hierarchy.
extension AddItemSheet {
    var flightSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.md) {
                FormTextField(label: "Airline", text: $airline, placeholder: "TAP Air Portugal")
                FormTextField(label: "Flight no.", text: $flightNo, placeholder: "TP1234", autocapitalization: .characters)
            }
            HStack(spacing: Spacing.md) {
                FormTextField(label: "From", text: $fromIATA, placeholder: "e.g. JFK", autocapitalization: .characters)
                    .onChange(of: fromIATA) { _, newValue in
                        let filtered = String(newValue.uppercased().prefix(3))
                        if filtered != fromIATA { fromIATA = filtered }
                        if let id = AirportTimeZones.tzIdentifier(for: filtered), let zone = TimeZone(identifier: id) {
                            departureZone = zone
                        }
                    }
                FormTextField(label: "To", text: $toIATA, placeholder: "e.g. LIS", autocapitalization: .characters)
                    .onChange(of: toIATA) { _, newValue in
                        let filtered = String(newValue.uppercased().prefix(3))
                        if filtered != toIATA { toIATA = filtered }
                        if let id = AirportTimeZones.tzIdentifier(for: filtered), let zone = TimeZone(identifier: id) {
                            arrivalZone = zone
                        }
                    }
            }

            LabeledDatePicker(label: "Date", date: $flightDate, displayedComponents: .date)

            LabeledDatePicker(label: "Departs", date: $departsTime, displayedComponents: .hourAndMinute)
            ZonePicker(
                title: "Departure time zone", selection: $departureZone, referenceDate: departsTime,
                hint: isDepartureZoneAutoSet ? "Set by departure airport" : nil
            )
            if isDepartureAirportUnknown {
                // Finding 6: advisory (slate), not an error — the zone
                // default is still usable, this just flags that it wasn't
                // actually detected from the code typed.
                Text("We couldn\u{2019}t detect this airport \u{2014} double-check the time zone.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }

            LabeledDatePicker(label: "Arrives", date: $arrivesTime, displayedComponents: .hourAndMinute)
            HStack {
                Spacer(minLength: 0)
                nextDayChip
            }
            if !fromIATA.trimmingCharacters(in: .whitespaces).isEmpty
                && !toIATA.trimmingCharacters(in: .whitespaces).isEmpty
                && !flightEndAfterStart {
                Text("Arrival must be after departure.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.rose)
            }
            ZonePicker(
                title: "Arrival time zone", selection: $arrivalZone, referenceDate: arrivesTime,
                hint: isArrivalZoneAutoSet ? "Set by arrival airport" : nil
            )
            if isArrivalAirportUnknown {
                Text("We couldn\u{2019}t detect this airport \u{2014} double-check the time zone.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }

            HStack(spacing: Spacing.md) {
                FormTextField(label: "Seat", text: $seat, placeholder: "14C", autocapitalization: .characters)
                FormTextField(label: "Terminal", text: $terminal, placeholder: "1")
                FormTextField(label: "Gate", text: $gate, placeholder: "22")
            }
            FormTextField(
                label: "Confirmation code", text: $confirmation, placeholder: "QK7P2M", autocapitalization: .characters
            )
        }
    }

    var staySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            FormTextField(label: "Hotel name", text: $stayName, placeholder: "Memmo Alfama")

            HStack(spacing: Spacing.md) {
                LabeledDatePicker(label: "Check-in date", date: $checkInDate, displayedComponents: .date)
                LabeledDatePicker(label: "Time", date: $checkInTime, displayedComponents: .hourAndMinute)
            }
            HStack(spacing: Spacing.md) {
                LabeledDatePicker(label: "Check-out date", date: $checkOutDate, displayedComponents: .date)
                LabeledDatePicker(label: "Time", date: $checkOutTime, displayedComponents: .hourAndMinute)
            }
            if stayHasName && !stayEndAfterStart {
                Text("Check-out must be after check-in.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.rose)
            }
            ZonePicker(title: "Hotel time zone", selection: $stayZone, referenceDate: checkInTime)

            LocationField(label: "Address", text: $locationText) { coordinate, resolvedAddress in
                locationLat = coordinate?.latitude
                locationLng = coordinate?.longitude
                address = resolvedAddress
            }

            FormTextField(label: "Room", text: $room, placeholder: "412")
            FormTextField(
                label: "Confirmation code", text: $confirmation, placeholder: "HTL-88213", autocapitalization: .characters
            )
        }
    }

    var activitySection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            FormTextField(label: "Title", text: $activityTitle, placeholder: "Belém Tower")

            HStack(spacing: Spacing.md) {
                LabeledDatePicker(label: "Date", date: $activityDate, displayedComponents: .date)
                LabeledDatePicker(label: "Time", date: $activityTime, displayedComponents: .hourAndMinute)
            }
            ZonePicker(title: "Time zone", selection: $activityZone, referenceDate: activityTime)

            LocationField(label: "Address", text: $locationText) { coordinate, resolvedAddress in
                locationLat = coordinate?.latitude
                locationLng = coordinate?.longitude
                address = resolvedAddress
            }

            FormTextField(label: "Ticket reference", text: $ticketRef, placeholder: "TKT-4471")
        }
    }

    var foodSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            FormTextField(label: "Restaurant", text: $foodName, placeholder: "Cervejaria Ramiro")

            HStack(spacing: Spacing.md) {
                LabeledDatePicker(label: "Date", date: $foodDate, displayedComponents: .date)
                LabeledDatePicker(label: "Time", date: $foodTime, displayedComponents: .hourAndMinute)
            }
            ZonePicker(title: "Time zone", selection: $foodZone, referenceDate: foodTime)

            HStack(spacing: Spacing.md) {
                FormTextField(label: "Party size", text: $partySize, placeholder: "4", keyboardType: .numberPad)
                FormTextField(label: "Reservation name", text: $reservationName, placeholder: "Naveen")
            }

            LocationField(label: "Address", text: $locationText) { coordinate, resolvedAddress in
                locationLat = coordinate?.latitude
                locationLng = coordinate?.longitude
                address = resolvedAddress
            }

            // Finding 5: Food was the one category with no confirmation
            // field, so a Resy/OpenTable code had nowhere to go and could
            // never earn the §4.2 ticket glyph like every other category.
            FormTextField(
                label: "Confirmation code", text: $confirmation, placeholder: "RESY-88213", autocapitalization: .characters
            )
        }
    }

    var transportSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            FormTextField(label: "Title (optional)", text: $transportTitle, placeholder: "Rental car")
            FormTextField(label: "Provider", text: $provider, placeholder: "Hertz")

            LocationField(label: "Pickup location", text: $locationText) { coordinate, resolvedAddress in
                locationLat = coordinate?.latitude
                locationLng = coordinate?.longitude
                address = resolvedAddress
            }
            HStack(spacing: Spacing.md) {
                LabeledDatePicker(label: "Pickup date", date: $transportDate, displayedComponents: .date)
                LabeledDatePicker(label: "Time", date: $pickupTime, displayedComponents: .hourAndMinute)
            }
            ZonePicker(title: "Pickup time zone", selection: $pickupZone, referenceDate: pickupTime)

            LocationField(label: "Drop-off location", text: $dropoffText) { _, _ in }
            Button("Same as pickup") { dropoffText = locationText }
                .font(Typo.body(11, weight: .semibold))
                .foregroundStyle(Palette.amber)
                .frame(maxWidth: .infinity, alignment: .trailing)
            HStack(spacing: Spacing.md) {
                LabeledDatePicker(label: "Drop-off date", date: $dropoffDate, displayedComponents: .date)
                LabeledDatePicker(label: "Time", date: $dropoffTime, displayedComponents: .hourAndMinute)
            }
            if transportHasName && !transportEndAfterStart {
                Text("Drop-off must be after pickup.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.rose)
            }
            Toggle("Returns in a different time zone", isOn: $transportDropoffDiffZone)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .tint(Palette.amber)
            if transportDropoffDiffZone {
                ZonePicker(title: "Drop-off time zone", selection: $dropoffZone, referenceDate: dropoffTime)
            }

            FormTextField(
                label: "Confirmation code", text: $confirmation, placeholder: "ABC123", autocapitalization: .characters
            )
        }
    }

    // MARK: - Family: "Who's this for?" + kid-aware tags (M4 §3), shared
    // across every category — appended once after the category switch.

    @ViewBuilder
    var familySection: some View {
        if canManageAssignees {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if !tripProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Who\u{2019}s this for?")
                            .font(Typo.body(Typo.Size.caption, weight: .semibold))
                            .foregroundStyle(Palette.slate)
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Spacing.sm) {
                                ForEach(tripProfiles) { profile in
                                    assigneeChipToggle(profile)
                                }
                            }
                        }
                        Text("Leave everyone unselected if it\u{2019}s for the whole group.")
                            .helperTextStyle()
                    }
                }

                let categoryTags = ItemTag.allowed(for: category)
                if !categoryTags.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Family tags")
                            .font(Typo.body(Typo.Size.caption, weight: .semibold))
                            .foregroundStyle(Palette.slate)
                        HStack(spacing: Spacing.sm) {
                            ForEach(categoryTags, id: \.self) { tag in
                                tagToggle(tag)
                            }
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
        }
    }

    private func assigneeChipToggle(_ profile: TripProfile) -> some View {
        let isOn = selectedAssigneeProfileIds.contains(profile.id)
        let color = AvatarColor.color(named: profile.avatarColor)
        return Button {
            if isOn { selectedAssigneeProfileIds.remove(profile.id) } else { selectedAssigneeProfileIds.insert(profile.id) }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(isOn ? .white.opacity(0.3) : color)
                    .frame(width: 20, height: 20)
                    .overlay {
                        Text(profile.displayName.prefix(1).uppercased())
                            .font(Typo.body(9, weight: .bold))
                            .foregroundStyle(.white)
                    }
                Text(profile.displayName.split(separator: " ").first.map(String.init) ?? profile.displayName)
                    .font(Typo.body(12.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? .white : Palette.slate)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + 2)
            .background(isOn ? color : Palette.elevated, in: Capsule())
            .overlay {
                Capsule().stroke(isOn ? Color.clear : Palette.mist, lineWidth: 1)
            }
            // Finding 4 (§6.5 44pt floor) — see `nextDayChip`'s comment.
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func tagToggle(_ tag: ItemTag) -> some View {
        let isOn = selectedTags.contains(tag.rawValue)
        return Button {
            if isOn { selectedTags.remove(tag.rawValue) } else { selectedTags.insert(tag.rawValue) }
        } label: {
            HStack(spacing: 4) {
                if let symbolName = tag.symbolName {
                    Image(systemName: symbolName).font(.system(size: 10, weight: .semibold))
                }
                Text(tag.label).font(Typo.body(11.5, weight: .semibold))
            }
            .foregroundStyle(isOn ? .white : CategoryColor.activity.fg)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + 2)
            .background(isOn ? CategoryColor.activity.fg : CategoryColor.activity.soft, in: Capsule())
            // Finding 4 (§6.5 44pt floor) — see `nextDayChip`'s comment.
            .frame(minHeight: 44)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    // MARK: - Zone-hint derivation (this milestone's brief: "every time
    // field shows its zone label ... set by departure airport")

    var isDepartureZoneAutoSet: Bool {
        guard let id = AirportTimeZones.tzIdentifier(for: fromIATA) else { return false }
        return id == departureZone.identifier
    }

    /// Finding 6: a complete-looking (3-letter) code that `AirportTimeZones`
    /// still can't resolve — the departure zone quietly falls back to
    /// whatever it was defaulted to (last-used or trip zone), which is
    /// usually wrong for an unrecognized airport. This flags that the zone
    /// picker's value needs a manual check (§7.4 time-correctness), without
    /// blocking save — the default is still a usable starting point.
    var isDepartureAirportUnknown: Bool {
        let code = fromIATA.trimmingCharacters(in: .whitespaces)
        return code.count == 3 && AirportTimeZones.tzIdentifier(for: code) == nil
    }

    var isArrivalZoneAutoSet: Bool {
        guard let id = AirportTimeZones.tzIdentifier(for: toIATA) else { return false }
        return id == arrivalZone.identifier
    }

    /// Finding 6, arrival counterpart to `isDepartureAirportUnknown`.
    var isArrivalAirportUnknown: Bool {
        let code = toIATA.trimmingCharacters(in: .whitespaces)
        return code.count == 3 && AirportTimeZones.tzIdentifier(for: code) == nil
    }

    var nextDayChip: some View {
        Button {
            arrivalDayOffsetOverride = !effectiveNextDay
        } label: {
            Text("+1 day")
                .font(Typo.body(11, weight: .semibold))
                .foregroundStyle(effectiveNextDay ? .white : Palette.slate)
                .padding(.horizontal, Spacing.sm)
                .padding(.vertical, Spacing.xs)
                .background(effectiveNextDay ? Palette.amber : Palette.mist, in: Capsule())
                // Finding 4 (§6.5 44pt floor): applied after the background
                // so the visual pill stays compact at its natural size —
                // this only grows the invisible tappable frame around it,
                // with `.contentShape` extending hit-testing to match.
                .frame(minHeight: 44)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Arrives next day")
        .accessibilityAddTraits(effectiveNextDay ? [.isSelected] : [])
    }
}

/// A single labeled text input matching the mockup's `Field` component
/// (rounded 13pt border, label above) — this file's one shared text-input
/// look, so flight/stay/activity/food fields don't each hand-roll it.
///
/// Generic over an optional `FocusValue` (UX audit finding 1): `.focused` is
/// only documented-reliable on the actual focusable control, not a wrapping
/// `VStack`, so a caller that needs focus forwarding supplies `focusBinding`
/// + `focusValue` and both land on the inner `TextField` directly. Callers
/// that don't care about focus (the ~24 existing call sites) keep using the
/// plain `init` below, which pins `FocusValue == Bool` and leaves both nil —
/// no call-site changes required.
struct FormTextField<FocusValue: Hashable>: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences
    var focusBinding: FocusState<FocusValue>.Binding?
    var focusValue: FocusValue?

    /// UX audit finding 2: the fallback focus target for the ~24 call sites
    /// that don't supply their own `focusBinding` — the tap-to-focus gesture
    /// below still needs *something* to drive when the caller hasn't wired
    /// one up itself.
    @FocusState private var fallbackFocus: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.slate)
            textField
                .font(Typo.body())
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm + 2)
                .frame(minHeight: 44) // BUILD_PLAN §6.5
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                        .stroke(Palette.mist, lineWidth: 1)
                }
                // Padding/frame alone don't extend a `TextField`'s focusable
                // hit region, so a tap that lands in the padding (rather
                // than directly on the UIKit-backed text field) would
                // otherwise do nothing. Taps on the text itself still reach
                // it normally for cursor placement.
                .contentShape(RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .onTapGesture {
                    if let focusBinding, let focusValue {
                        focusBinding.wrappedValue = focusValue
                    } else {
                        fallbackFocus = true
                    }
                }
        }
    }

    @ViewBuilder
    private var textField: some View {
        if let focusBinding, let focusValue {
            TextField(placeholder, text: $text)
                .focused(focusBinding, equals: focusValue)
        } else {
            TextField(placeholder, text: $text)
                .focused($fallbackFocus)
        }
    }
}

extension FormTextField where FocusValue == Bool {
    /// The no-focus-forwarding shape every existing call site uses —
    /// `focusBinding`/`focusValue` stay at their `nil` defaults.
    init(
        label: String,
        text: Binding<String>,
        placeholder: String = "",
        keyboardType: UIKeyboardType = .default,
        autocapitalization: TextInputAutocapitalization = .sentences
    ) {
        self.label = label
        self._text = text
        self.placeholder = placeholder
        self.keyboardType = keyboardType
        self.autocapitalization = autocapitalization
    }
}

/// A labeled date-or-time picker in the same visual frame as `FormTextField`
/// — every time field the brief calls for shows its zone label via a
/// neighboring `ZonePicker`, not baked into this row itself.
struct LabeledDatePicker: View {
    let label: String
    @Binding var date: Date
    var displayedComponents: DatePickerComponents = .date
    /// Lower bound for the picker (F8) — e.g. a trip's end date can't be
    /// dragged before its start date. `nil` keeps the picker unbounded.
    var minDate: Date? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.slate)
                // UX audit finding 3: the picker below carries this same
                // label for VoiceOver (see the `DatePicker(label, ...)`
                // calls) — hiding this static duplicate keeps it from being
                // announced a second time as its own element.
                .accessibilityHidden(true)
            Spacer(minLength: Spacing.sm)
            Group {
                if let minDate {
                    DatePicker(label, selection: $date, in: minDate..., displayedComponents: displayedComponents)
                } else {
                    DatePicker(label, selection: $date, displayedComponents: displayedComponents)
                }
            }
            // `.labelsHidden()` only hides the label visually — it's still
            // read by VoiceOver, so this becomes "Starts, date picker, May
            // 14, 2026" instead of just the bare value (finding 3).
            .labelsHidden()
            .tint(Palette.amber)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                .stroke(Palette.mist, lineWidth: 1)
        }
    }
}
