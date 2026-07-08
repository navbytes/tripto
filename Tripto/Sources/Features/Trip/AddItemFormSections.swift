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
                FormTextField(label: "From", text: $fromIATA, placeholder: "JFK", autocapitalization: .characters)
                    .onChange(of: fromIATA) { _, newValue in
                        let filtered = String(newValue.uppercased().prefix(3))
                        if filtered != fromIATA { fromIATA = filtered }
                        if let id = AirportTimeZones.tzIdentifier(for: filtered), let zone = TimeZone(identifier: id) {
                            departureZone = zone
                        }
                    }
                FormTextField(label: "To", text: $toIATA, placeholder: "LIS", autocapitalization: .characters)
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

            LabeledDatePicker(label: "Arrives", date: $arrivesTime, displayedComponents: .hourAndMinute)
            HStack {
                Spacer(minLength: 0)
                nextDayChip
            }
            ZonePicker(
                title: "Arrival time zone", selection: $arrivalZone, referenceDate: arrivesTime,
                hint: isArrivalZoneAutoSet ? "Set by arrival airport" : nil
            )

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
            if !isValid {
                Text("Check-out must be after check-in.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(.red)
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
        }
    }

    var transportSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            FormTextField(label: "Title", text: $transportTitle, placeholder: "Rental car")
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

            FormTextField(label: "Drop-off location", text: $dropoffText, placeholder: "Airport, hotel, depot\u{2026}")
            HStack(spacing: Spacing.md) {
                LabeledDatePicker(label: "Drop-off date", date: $dropoffDate, displayedComponents: .date)
                LabeledDatePicker(label: "Time", date: $dropoffTime, displayedComponents: .hourAndMinute)
            }
            if !transportTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !transportEndAfterStart {
                Text("Drop-off must be after pickup.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(.red)
            }
            ZonePicker(title: "Drop-off time zone", selection: $dropoffZone, referenceDate: dropoffTime)

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
                            .font(Typo.body(9.5))
                            .foregroundStyle(Palette.slate.opacity(0.8))
                    }
                }

                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Family tags")
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(Palette.slate)
                    HStack(spacing: Spacing.sm) {
                        ForEach(ItemTag.allCases, id: \.self) { tag in
                            tagToggle(tag)
                        }
                        Spacer(minLength: 0)
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

    var isArrivalZoneAutoSet: Bool {
        guard let id = AirportTimeZones.tzIdentifier(for: toIATA) else { return false }
        return id == arrivalZone.identifier
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
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Arrives next day")
        .accessibilityAddTraits(effectiveNextDay ? [.isSelected] : [])
    }
}

/// A single labeled text input matching the mockup's `Field` component
/// (rounded 13pt border, label above) — this file's one shared text-input
/// look, so flight/stay/activity/food fields don't each hand-roll it.
struct FormTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var keyboardType: UIKeyboardType = .default
    var autocapitalization: TextInputAutocapitalization = .sentences

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.slate)
            TextField(placeholder, text: $text)
                .keyboardType(keyboardType)
                .textInputAutocapitalization(autocapitalization)
                .autocorrectionDisabled()
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm + 2)
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                        .stroke(Palette.mist, lineWidth: 1)
                }
        }
    }
}

/// A labeled date-or-time picker in the same visual frame as `FormTextField`
/// — every time field the brief calls for shows its zone label via a
/// neighboring `ZonePicker`, not baked into this row itself.
struct LabeledDatePicker: View {
    let label: String
    @Binding var date: Date
    var displayedComponents: DatePickerComponents = .date

    var body: some View {
        HStack {
            Text(label)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.slate)
            Spacer(minLength: Spacing.sm)
            DatePicker("", selection: $date, displayedComponents: displayedComponents)
                .labelsHidden()
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
