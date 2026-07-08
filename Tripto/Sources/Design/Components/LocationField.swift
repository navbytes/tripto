import MapKit
import SwiftUI

/// Free-text location field with on-device autocomplete (this milestone's
/// brief §4.3: "Location field: plain text + MKLocalSearchCompleter
/// on-device suggestions (fills location_name + lat/lng on pick). NO Google
/// APIs"). Plain typing with no suggestion tapped is still a fully valid
/// save (BUILD_PLAN.md §4.3: "in v1 plain text is acceptable").
struct LocationField: View {
    let label: String
    @Binding var text: String
    /// Fires only when the user taps a suggestion — carries the resolved
    /// coordinate (may be `nil`; MapKit resolution is best-effort) and the
    /// completion's subtitle as a fuller street-address string.
    var onSelect: (_ coordinate: CLLocationCoordinate2D?, _ address: String?) -> Void = { _, _ in }

    @State private var completer = LocationSearchCompleter()
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(label)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.slate)

            HStack(spacing: Spacing.sm) {
                Image(systemName: "mappin.and.ellipse").foregroundStyle(Palette.slate)
                TextField("Search a place or type an address", text: $text)
                    .focused($isFocused)
                    .onChange(of: text) { _, newValue in
                        completer.update(query: newValue)
                    }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm + 2)
            .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                    .stroke(Palette.mist, lineWidth: 1)
            }

            if isFocused, !completer.results.isEmpty {
                suggestionsList
            }
        }
    }

    private var suggestionsList: some View {
        let results = completer.results
        return VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(results.enumerated()), id: \.offset) { index, result in
                Button {
                    select(result)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(result.title)
                            .font(Typo.body(weight: .medium))
                            .foregroundStyle(Palette.ink)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle)
                                .font(Typo.body(Typo.Size.caption))
                                .foregroundStyle(Palette.slate)
                        }
                    }
                    .padding(.horizontal, Spacing.md)
                    .padding(.vertical, Spacing.sm)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if index != results.count - 1 {
                    Divider().padding(.leading, Spacing.md)
                }
            }
        }
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                .stroke(Palette.mist, lineWidth: 1)
        }
    }

    private func select(_ result: MKLocalSearchCompletion) {
        text = result.title
        isFocused = false
        completer.clear()
        Task {
            let coordinate = await completer.resolve(result)
            onSelect(coordinate, result.subtitle.isEmpty ? nil : result.subtitle)
        }
    }
}
