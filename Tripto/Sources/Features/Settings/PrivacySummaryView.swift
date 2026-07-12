import SwiftUI

/// "Your privacy at a glance" — plain-language reassurance for the app's
/// actual data handling, reached via the "Privacy" row in `SettingsView`'s
/// About section (a plain `NavigationLink`, not a registered `*Route`: this
/// screen carries no associated data and stays entirely inside
/// Features/Settings, so it doesn't need a spot in `TripView.swift`'s
/// shared route enum — see that file's doc comment for the app's route
/// convention). Every line below is checked against
/// `web/share-worker/privacy-policy.md` and `docs/PRIVACY_DISCLOSURE.md`;
/// this is a summary of that policy, not a replacement for it, hence the
/// link at the bottom to the full published text — the same URL the old
/// About→"Privacy policy" row used to open directly.
struct PrivacySummaryView: View {
    @ScaledMetric(relativeTo: .body) private var iconSide: CGFloat = 36

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                Text(
                    "A plain-language summary of how Tripto handles your data \u{2014} "
                        + "not the legal version, just the facts."
                )
                .font(Typo.body(Typo.Size.caption))
                .foregroundStyle(Palette.slate)

                VStack(alignment: .leading, spacing: Spacing.lg) {
                    ForEach(Self.points) { point in
                        pointRow(point)
                    }
                }

                Link(destination: Self.privacyURL) {
                    HStack(spacing: Spacing.xs) {
                        Text("Read the full privacy policy")
                            .font(Typo.body(weight: .semibold))
                        Image(systemName: "arrow.up.forward.square")
                            .accessibilityHidden(true)
                    }
                    .foregroundStyle(Palette.amberInk)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
                }
            }
            .padding(Spacing.xl)
        }
        .background(Palette.paper)
        .navigationTitle("Your privacy at a glance")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pointRow(_ point: PrivacyPoint) -> some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: iconSide * 0.29, style: .continuous)
                    .fill(Palette.amberSoft)
                Image(systemName: point.symbolName)
                    .font(.system(size: iconSide * 0.47, weight: .medium))
                    .foregroundStyle(Palette.amber)
            }
            .frame(width: iconSide, height: iconSide)
            // Decorative — hidden so VoiceOver doesn't also read the SF
            // Symbol's own auto-generated name (e.g. "person 2 fill")
            // before the title/body pair below; the `.combine` on this
            // HStack then reads just "title. body." as one stop.
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(point.title)
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(Palette.ink)
                Text(point.body)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private struct PrivacyPoint: Identifiable {
        let id: String
        let symbolName: String
        let title: String
        let body: String
    }

    // Order mirrors the source docs: who can see your trip, what a public
    // link leaves out, the one place a third party is involved, how to
    // leave, and what we simply don't do.
    private static let points: [PrivacyPoint] = [
        PrivacyPoint(
            id: "shared",
            symbolName: "person.2.fill",
            title: "Shared only with people you invite",
            body: "Your trip is visible only to the members you add \u{2014} protected by row-level "
                + "security, so no one else can read it."
        ),
        PrivacyPoint(
            id: "shareLink",
            symbolName: "eye.slash",
            title: "Public share links show only the basics",
            body: "A share link never includes confirmation codes, notes, exact coordinates, or "
                + "member emails."
        ),
        PrivacyPoint(
            id: "import",
            symbolName: "sparkles",
            title: "AI helps only when you paste to import",
            body: "On supported iPhones you choose where processing happens \u{2014} on-device by default "
                + "(never leaves), or cloud AI (via Cloudflare) if you prefer; other iPhones always use "
                + "the cloud. It isn\u{2019}t stored in your account afterward, and we ask permission "
                + "before the first cloud send."
        ),
        PrivacyPoint(
            id: "delete",
            symbolName: "trash",
            title: "Delete your account anytime",
            body: "Deleting in Settings is immediate and permanent, and also revokes Tripto\u{2019}s "
                + "Apple sign-in."
        ),
        PrivacyPoint(
            id: "noAds",
            symbolName: "nosign",
            title: "No ads, no tracking, no analytics",
            body: "We don\u{2019}t run ads, track you, or use analytics \u{2014} ever."
        )
    ]

    /// Served live by the share Worker (web/share-worker/src/index.ts:
    /// GET /privacy -> renderPrivacyPage, HTTP 200) — same URL the old
    /// About-section link opened. Host comes from DeepLink so the domain
    /// lives in exactly one place.
    static let privacyURL = URL(string: "https://\(DeepLink.host)/privacy")!
}

#Preview {
    NavigationStack {
        PrivacySummaryView()
    }
}
