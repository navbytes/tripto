import SwiftUI

/// The Cancel / centered-bold-title / balancing-hidden-Cancel header pattern
/// every branded sheet uses (originally `AddItemSheet.header`) — factored out
/// so `TripFormView`'s rebuild shares the exact same chrome (BUILD_PLAN.md
/// §6.1/§6.4) instead of a second hand-rolled copy.
struct SheetHeader: View {
    let title: String
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel", action: onCancel)
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(Palette.slate)
                    // BUILD_PLAN §6.5's 44pt floor (finding 2) — matches
                    // SegmentedControl.swift and HomeView.swift's CTAs.
                    .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                Spacer()
                Text(title)
                    .font(Typo.body(weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer()
                // Balances the leading button — same frame so the title
                // stays centered once Cancel grows to the 44pt floor.
                Text("Cancel")
                    .font(Typo.body(weight: .semibold))
                    .opacity(0)
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.xs)
            .padding(.bottom, Spacing.xxs)

            Rectangle().fill(Palette.mist).frame(height: 1)
        }
    }
}

#Preview {
    SheetHeader(title: "Plan a new trip", onCancel: {})
}
