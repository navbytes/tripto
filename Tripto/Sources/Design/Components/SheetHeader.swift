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
                    // D2 defect 5: at AX5 the title/trailing-balance Spacers
                    // squeezed this below its one-word natural width, and
                    // with no `.lineLimit`/`.fixedSize` it wrapped mid-word
                    // ("Cance"/"l"). `fixedSize()` pins it to its own ideal
                    // (single-line) size regardless of what the HStack
                    // offers — a short, essential word like "Cancel" is
                    // cheap to always render whole; the title (already
                    // `.lineLimit(1)`, unchanged) absorbs the squeeze
                    // instead, same as it already does today. No-op at
                    // default size (natural width already fit).
                    .fixedSize()
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
                // Balances the leading button — same frame (and now the
                // same `fixedSize()`, D2 defect 5) so the title stays
                // centered once Cancel grows past the 44pt floor.
                // `.opacity(0)` only hides it visually; VoiceOver can still
                // land on it and speak a phantom "Cancel" unless hidden
                // explicitly.
                Text("Cancel")
                    .font(Typo.body(weight: .semibold))
                    .opacity(0)
                    .fixedSize()
                    .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                    .accessibilityHidden(true)
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
