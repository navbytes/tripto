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

private struct ZonePickerList: View {
    @Binding var selection: TimeZone
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private static let allIdentifiers: [String] = TimeZone.knownTimeZoneIdentifiers.sorted()

    private var identifiers: [String] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return Self.allIdentifiers }
        return Self.allIdentifiers.filter {
            $0.localizedCaseInsensitiveContains(query)
                || ItineraryTimeZone.citySegment(of: $0).localizedCaseInsensitiveContains(query)
        }
    }

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
