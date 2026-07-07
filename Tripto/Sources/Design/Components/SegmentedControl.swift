import SwiftUI

/// The pill-style segmented control from the mockups (`TripApp.jsx`'s
/// `Segmented`) — Home's Upcoming/Past toggle (BUILD_PLAN.md §6.4). A
/// sliding white/elevated pill on a `mist` track, not the native iOS
/// segmented style.
struct SegmentedControl: View {
    let options: [String]
    @Binding var selection: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                Button {
                    if reduceMotion {
                        selection = option
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { selection = option }
                    }
                } label: {
                    Text(option)
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(option == selection ? Palette.ink : Palette.slate)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if option == selection {
                        RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous)
                            .fill(Palette.elevated)
                            .shadow(color: Palette.ink.opacity(0.12), radius: 3, y: 1)
                    }
                }
                .accessibilityAddTraits(option == selection ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(Palette.mist, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
    }
}

private struct SegmentedControlPreview: View {
    @State private var selection = "Upcoming"

    var body: some View {
        SegmentedControl(options: ["Upcoming", "Past"], selection: $selection)
            .padding(Spacing.xl)
            .background(Palette.paper)
    }
}

#Preview {
    SegmentedControlPreview()
}
