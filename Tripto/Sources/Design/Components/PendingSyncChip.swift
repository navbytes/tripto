import SwiftUI

/// Row-level "waiting to sync" indicator (SYNC_DESIGN.md "Status surface";
/// ACCEPTANCE.md "(e)" — "a small clock glyph"). Shown on a trip card when
/// its id is in `SyncStatus.pendingRowIds`.
struct PendingSyncChip: View {
    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Image(systemName: "clock")
                .font(.system(size: 10, weight: .semibold))
            Text("Waiting to sync")
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
        }
        .foregroundStyle(Palette.slate)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xxs)
        .background(Palette.mist, in: RoundedRectangle(cornerRadius: Radii.pill, style: .continuous))
    }
}

#Preview {
    PendingSyncChip()
        .padding(Spacing.xl)
        .background(Palette.paper)
}
