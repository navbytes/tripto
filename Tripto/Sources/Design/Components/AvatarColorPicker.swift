import SwiftUI

/// Four-swatch avatar-color picker (amber/moss/sky/plum — the palette
/// `AvatarColor.color(named:)` actually resolves). Originally
/// `TripProfileFormSheet`'s inline swatch row; extracted (UX audit finding
/// 9) so Settings' own profile section can offer the same control instead of
/// leaving the signed-in user's own avatar color fixed and uneditable.
struct AvatarColorPicker: View {
    static let swatches = ["amber", "moss", "sky", "plum"]

    @Binding var selection: String
    var swatchSize: CGFloat = 36

    var body: some View {
        // `Spacing.sm` matches `TripProfileFormSheet`'s original inline row
        // this was extracted from — preserved so that sheet's visual is
        // unchanged.
        HStack(spacing: Spacing.sm) {
            ForEach(Self.swatches, id: \.self) { swatch in
                swatchButton(swatch)
            }
        }
    }

    /// BUILD_PLAN §6.5's 44pt tap-target floor — the swatch stays
    /// `swatchSize` *visually*, but its tappable area grows to 44x44,
    /// centered on the same circle (`TripProfileFormSheet`'s original
    /// finding-6 fix, preserved when this was extracted).
    private func swatchButton(_ swatch: String) -> some View {
        let isOn = selection == swatch
        return Button {
            selection = swatch
        } label: {
            Circle()
                .fill(AvatarColor.color(named: swatch))
                .frame(width: swatchSize, height: swatchSize)
                .overlay {
                    if isOn {
                        Image(systemName: "checkmark")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .overlay {
                    Circle().stroke(isOn ? Palette.ink.opacity(0.25) : Color.clear, lineWidth: 2)
                        .padding(-3)
                }
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(swatch.capitalized)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }
}

#Preview {
    @Previewable @State var selection = "sky"
    return AvatarColorPicker(selection: $selection)
        .padding(Spacing.xl)
        .background(Palette.paper)
}
