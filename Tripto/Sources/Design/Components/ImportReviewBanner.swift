import SwiftUI

/// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): "N imported booking(s) to review" —
/// shown on the Itinerary tab whenever the trip has any `status ==
/// 'suggested'` item. Clones `SyncIssueBanner`'s layout/placement, but in
/// the amber/sky "heads up, not an error" treatment rather than rose — an
/// unreviewed suggestion is an invitation to look, not a failure.
struct ImportReviewBanner: View {
    let count: Int
    let onTap: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var chevronSize: CGFloat = 11

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "envelope.badge")
                Text(Self.bannerText(count: count))
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: chevronSize, weight: .semibold))
                    .opacity(0.7)
            }
            .foregroundStyle(Palette.amberInk)
            .padding(.horizontal, Spacing.lg)
            .padding(.vertical, Spacing.sm)
            .background(Palette.amberSoft)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.bannerText(count: count))
        .accessibilityHint("Opens the imported bookings to review")
        .accessibilityAddTraits(.isButton)
        .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: count)
    }

    static func bannerText(count: Int) -> String {
        count == 1 ? "1 imported booking to review" : "\(count) imported bookings to review"
    }
}

#Preview {
    VStack {
        ImportReviewBanner(count: 1) {}
        ImportReviewBanner(count: 3) {}
        Spacer()
    }
    .padding(.top, Spacing.xl)
    .background(Palette.paper)
}
