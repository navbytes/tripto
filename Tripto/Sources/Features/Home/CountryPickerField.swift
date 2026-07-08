import SwiftUI

/// Searchable country picker (UX audit finding 3) — replaces the raw
/// "type a 2-letter ISO code" `FormTextField` `TripFormView` used to show,
/// which made invalid codes trivially easy to enter (`"PO"` instead of
/// `"PT"`) and forced a rejection hint onto the form. Selecting from this
/// list makes an invalid code unrepresentable, so `TripFormValidation`'s
/// `isCountryCodeAcceptable`/`countryName(forCode:)` checks become
/// defensive-only here — still exercised for edit mode against legacy or
/// synced data that predates the picker.
///
/// Matches `FormTextField`'s exact visual frame (label above, `Palette
/// .elevated` fill, `Radii.card`, `Palette.mist` stroke) so it reads as the
/// same field type in the form, just picker-shaped instead of type-shaped.
struct CountryPickerField: View {
    let label: String
    @Binding var code: String

    @State private var isPresented = false

    /// The selected country's resolved display, when the code is a real,
    /// assigned ISO region.
    private var resolved: TripFormValidation.Country? {
        TripFormValidation.allCountries.first { $0.code.caseInsensitiveCompare(code) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.slate)
            Button {
                isPresented = true
            } label: {
                HStack {
                    fieldContent
                    Spacer(minLength: Spacing.sm)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Palette.slate)
                }
                .font(Typo.body())
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm + 2)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) // BUILD_PLAN §6.5
                .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                        .stroke(Palette.mist, lineWidth: 1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(label)
            .accessibilityValue(accessibilityValue)
        }
        .sheet(isPresented: $isPresented) {
            CountryPickerSheet(code: $code)
        }
    }

    @ViewBuilder
    private var fieldContent: some View {
        if let resolved {
            Text("\(resolved.flag) \(resolved.name)")
                .foregroundStyle(Palette.ink)
        } else if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            // Edit mode, unresolvable legacy/synced code: shown raw rather
            // than hidden, so nothing silently disappears out from under
            // the user (finding F3 makes new entries unrepresentable, but
            // existing bad data still needs to be visible and editable).
            Text(code)
                .foregroundStyle(Palette.ink)
        } else {
            Text("Optional")
                .foregroundStyle(.tertiary)
        }
    }

    private var accessibilityValue: String {
        if let resolved { return resolved.name }
        if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return code }
        return "Optional"
    }
}

private struct CountryPickerSheet: View {
    @Binding var code: String
    @Environment(\.dismiss) private var dismiss

    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var results: [TripFormValidation.Country] {
        TripFormValidation.countries(matching: query)
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeader(title: "Choose a country", onCancel: { dismiss() })
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    FormTextField(
                        label: "Search",
                        text: $query,
                        placeholder: "Country name or code",
                        autocapitalization: .words,
                        focusBinding: $searchFocused,
                        focusValue: true
                    )
                    .submitLabel(.done)
                    .onSubmit { searchFocused = false }
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.lg)
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                clearRow
                                // No rule into blankness when there are no
                                // rows below it (empty-results state).
                                if !results.isEmpty {
                                    Divider().padding(.leading, Spacing.xl)
                                }
                            }
                            ForEach(results) { country in
                                countryRow(country)
                                if country.id != results.last?.id {
                                    Divider().padding(.leading, Spacing.xl)
                                }
                            }
                            if results.isEmpty {
                                // Only reachable with a non-blank query — a
                                // blank query always returns every country.
                                Text(
                                    "Nothing matched \u{201C}\(trimmedQuery)\u{201D}. Try the country\u{2019}s " +
                                        "name \u{2014} cities like \u{201C}Lisbon\u{201D} won\u{2019}t match."
                                )
                                .font(Typo.body(Typo.Size.caption))
                                .foregroundStyle(Palette.slate)
                                .padding(.horizontal, Spacing.xl)
                                .padding(.top, Spacing.lg)
                            }
                        }
                        .padding(.bottom, Spacing.xl)
                    }
                    .scrollDismissesKeyboard(.interactively)
                }
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            searchFocused = true
        }
    }

    private var clearRow: some View {
        Button {
            code = ""
            dismiss()
        } label: {
            HStack {
                Text("No country")
                    .foregroundStyle(Palette.slate)
                Spacer()
            }
            .frame(minHeight: 44) // BUILD_PLAN §6.5
            .contentShape(Rectangle())
            .padding(.horizontal, Spacing.xl)
        }
        .buttonStyle(.plain)
    }

    private func countryRow(_ country: TripFormValidation.Country) -> some View {
        let isSelected = country.code.caseInsensitiveCompare(code) == .orderedSame
        return Button {
            code = country.code
            dismiss()
        } label: {
            HStack {
                Text("\(country.flag) \(country.name)")
                    .foregroundStyle(Palette.ink)
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Palette.amber)
                }
            }
            .frame(minHeight: 44) // BUILD_PLAN §6.5
            .contentShape(Rectangle())
            .padding(.horizontal, Spacing.xl)
        }
        .buttonStyle(.plain)
        // VoiceOver skips the decorative flag glyph — the country name alone
        // is the meaningful label, same intent as the old inline confirmation
        // text this picker replaces.
        .accessibilityLabel(country.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

#Preview {
    @Previewable @State var code = "PT"
    return CountryPickerField(label: "Country", code: $code)
        .padding(Spacing.xl)
        .background(Palette.paper)
}
