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
                Spacer()
                Text(title)
                    .font(Typo.body(weight: .bold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Spacer()
                Text("Cancel").font(Typo.body(weight: .semibold)).opacity(0) // balances the leading button
            }
            .padding(.horizontal, Spacing.lg)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.sm)

            Rectangle().fill(Palette.mist).frame(height: 1)
        }
    }
}

#Preview {
    SheetHeader(title: "Plan a new trip", onCancel: {})
}
