import SwiftUI

/// Home's offline banner (SYNC_DESIGN.md "Status surface"; M1 brief: "amber
/// strip"). Shown whenever `SyncStatus.isOffline` is true, including the
/// DEBUG `-simulateOffline` forced case.
struct SyncBanner: View {
    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "wifi.slash")
                .foregroundStyle(Palette.ink)
            Text("Offline — changes will sync when you're back")
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
        .background(Palette.amberSoft)
    }
}

#Preview {
    SyncBanner()
}
