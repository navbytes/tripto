import SwiftUI

/// Searchable IANA time-zone field (this milestone's brief §4.3: "arrival
/// IANA zone picker (searchable)"; BUILD_PLAN.md §7.4). Reused for every
/// zone-bearing field in `AddItemSheet` — flight departure/arrival, stay,
/// activity, food — so there is exactly one zone-search implementation and
/// one "zone label" caption format in the app.
struct ZonePicker: View {
    let title: String
    @Binding var selection: TimeZone
    /// Reference instant for the caption's live abbreviation — a zone's
    /// abbreviation can depend on the date (DST either side of a change).
    var referenceDate: Date = .now
    /// Small provenance note under the caption, e.g. "Set by departure
    /// airport" (this milestone's brief: "every time field shows its zone
    /// label"). Callers pass `nil` once the user has overridden the default.
    var hint: String?

    @State private var isPresented = false
    @ScaledMetric(relativeTo: .caption) private var chevronSize: CGFloat = 11

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typo.body(Typo.Size.caption, weight: .semibold))
                        .foregroundStyle(Palette.slate)
                    if let hint {
                        Text(hint)
                            .helperTextStyle()
                    }
                }
                Spacer()
                Text(captionText)
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: chevronSize, weight: .semibold))
                    .foregroundStyle(Palette.slate)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Palette.mist.opacity(0.5), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        .sheet(isPresented: $isPresented) {
            ZonePickerList(selection: $selection)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title): \(captionText)")
    }

    /// "New York time (EDT)" — the brief's exact caption format.
    var captionText: String {
        let city = ItineraryTimeZone.citySegment(of: selection.identifier).replacingOccurrences(of: "_", with: " ")
        let abbr = ItineraryTimeZone.zoneLabel(for: selection, at: referenceDate)
        return "\(city) time (\(abbr))"
    }
}

/// All known IANA identifiers, sorted once — shared by `ZonePickerList` and
/// F6's `HomeZonePickerList` below so there's exactly one cached list and one
/// search-match rule for every zone picker in the app.
private let allTimeZoneIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()

private func zoneIdentifiers(matching query: String) -> [String] {
    guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return allTimeZoneIdentifiers }
    return allTimeZoneIdentifiers.filter {
        $0.localizedCaseInsensitiveContains(query)
            || ItineraryTimeZone.citySegment(of: $0).localizedCaseInsensitiveContains(query)
    }
}

private struct ZonePickerList: View {
    @Binding var selection: TimeZone
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var identifiers: [String] { zoneIdentifiers(matching: query) }

    var body: some View {
        NavigationStack {
            List(identifiers, id: \.self) { identifier in
                Button {
                    if let zone = TimeZone(identifier: identifier) {
                        selection = zone
                    }
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(ItineraryTimeZone.citySegment(of: identifier).replacingOccurrences(of: "_", with: " "))
                                .foregroundStyle(Palette.ink)
                            Text(identifier)
                                .font(Typo.body(Typo.Size.caption))
                                .foregroundStyle(Palette.slate)
                        }
                        Spacer()
                        if identifier == selection.identifier {
                            Image(systemName: "checkmark").foregroundStyle(Palette.amber)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search cities or zones")
            .navigationTitle("Time zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    @Previewable @State var zone = TimeZone(identifier: "America/New_York")!
    return ZonePicker(title: "Departs", selection: $zone, hint: "Set by departure airport")
        .padding(Spacing.xl)
        .background(Palette.paper)
}

// MARK: - F6 (1.3): Home time zone

/// `SettingsView`'s "Home time zone" row. Same tap-to-open-sheet shape as
/// `ZonePicker` above, but the selection is the raw `@AppStorage` STRING
/// (empty = "Automatic" — follow the device's own zone) rather than a bound
/// `TimeZone`: unlike every `ZonePicker` call site (a flight/stay/activity
/// always has some real zone), "unset" is itself this row's valid, default
/// selection, so it can't reuse `ZonePicker`'s non-optional binding as-is.
struct HomeZonePicker: View {
    /// `HomeTimeZonePreference.appStorageKey`'s raw value — the caller owns
    /// the `@AppStorage` property (same convention `showPastTrips`/
    /// `suggestionAlertsEnabled` bindings use elsewhere in `SettingsView`).
    @Binding var selectionID: String

    @State private var isPresented = false
    @ScaledMetric(relativeTo: .caption) private var chevronSize: CGFloat = 11

    private var resolvedZone: TimeZone { HomeTimeZonePreference.resolve(id: selectionID) }

    /// "Automatic — New York time (EDT)" when unset (naming which zone
    /// Automatic currently resolves to, per this milestone's brief: "show
    /// the resolved current offset for clarity"), else just "New York time
    /// (EDT)" — same caption format `ZonePicker.captionText` uses.
    private var captionText: String {
        let city = ItineraryTimeZone.citySegment(of: resolvedZone.identifier).replacingOccurrences(of: "_", with: " ")
        let abbr = ItineraryTimeZone.zoneLabel(for: resolvedZone)
        let zoneText = "\(city) time (\(abbr))"
        return selectionID.isEmpty ? "Automatic \u{2014} \(zoneText)" : zoneText
    }

    var body: some View {
        Button {
            isPresented = true
        } label: {
            HStack(alignment: .firstTextBaseline) {
                Text("Home time zone")
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                Spacer()
                Text(captionText)
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .multilineTextAlignment(.trailing)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: chevronSize, weight: .semibold))
                    .foregroundStyle(Palette.slate)
                    .accessibilityHidden(true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 44pt floor (CLAUDE.md quality bar) — a plain caption-height row
        // would otherwise land short of it, same reasoning `ZonePicker`'s
        // AddItemSheet host rows already satisfy via their own padding.
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Home time zone: \(captionText)")
        .accessibilityHint("Double tap to change")
        .sheet(isPresented: $isPresented) {
            HomeZonePickerList(selectionID: $selectionID)
        }
    }
}

private struct HomeZonePickerList: View {
    @Binding var selectionID: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var identifiers: [String] { zoneIdentifiers(matching: query) }

    var body: some View {
        NavigationStack {
            List {
                Button {
                    selectionID = ""
                    dismiss()
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Automatic")
                                .foregroundStyle(Palette.ink)
                            Text("Uses this device\u{2019}s time zone")
                                .font(Typo.body(Typo.Size.caption))
                                .foregroundStyle(Palette.slate)
                        }
                        Spacer()
                        if selectionID.isEmpty {
                            Image(systemName: "checkmark").foregroundStyle(Palette.amber).accessibilityHidden(true)
                        }
                    }
                }
                .frame(minHeight: 44)
                .accessibilityAddTraits(selectionID.isEmpty ? .isSelected : [])

                ForEach(identifiers, id: \.self) { identifier in
                    Button {
                        selectionID = identifier
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(ItineraryTimeZone.citySegment(of: identifier).replacingOccurrences(of: "_", with: " "))
                                    .foregroundStyle(Palette.ink)
                                Text(identifier)
                                    .font(Typo.body(Typo.Size.caption))
                                    .foregroundStyle(Palette.slate)
                            }
                            Spacer()
                            if identifier == selectionID {
                                Image(systemName: "checkmark").foregroundStyle(Palette.amber).accessibilityHidden(true)
                            }
                        }
                    }
                    .frame(minHeight: 44)
                    .accessibilityAddTraits(identifier == selectionID ? .isSelected : [])
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search cities or zones")
            .navigationTitle("Home time zone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview("Home time zone") {
    @Previewable @State var selectionID = ""
    return Form {
        HomeZonePicker(selectionID: $selectionID)
    }
}
