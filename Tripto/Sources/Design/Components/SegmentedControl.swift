import SwiftUI

/// The pill-style segmented control from the mockups (`TripApp.jsx`'s
/// `Segmented`) — Home's Upcoming/Past toggle (BUILD_PLAN.md §6.4). A
/// sliding white/elevated pill on a `mist` track, not the native iOS
/// segmented style.
struct SegmentedControl: View {
    let options: [String]
    @Binding var selection: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        // Equal-width segments mid-word-wrap "Upcoming" at accessibility
        // sizes (QA follow-up to D2) — stack the pills vertically there;
        // HStackLayout(spacing: 2) is byte-identical to the old HStack at
        // default sizes.
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 2))
            : AnyLayout(HStackLayout(spacing: 2))
        layout {
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
                        .frame(minHeight: 44) // BUILD_PLAN §6.5's 44pt floor (finding 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background {
                    if option == selection {
                        RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous)
                            .fill(Palette.elevated)
                            // A hairline keeps the selected pill legible in dark
                            // mode, where the elevated fill sits close to the
                            // mist track (persona dry-run).
                            .overlay(
                                RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous)
                                    .stroke(Palette.slate.opacity(0.22), lineWidth: 1)
                            )
                            .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
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
