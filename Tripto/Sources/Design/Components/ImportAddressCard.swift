import SwiftUI

/// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): the trip's real, working email-import
/// address — forwarding to it lands a suggestion in the review inbox
/// (`ImportReviewBanner` / `SuggestedItemsSheet`). Shows the real address, a
/// loading spinner while it's being fetched, or (reviewer should-fix: a
/// durable RPC failure used to leave the loading spinner up forever, now on
/// an always-visible card via `ShareTripView.importCard`, not just the old
/// empty-state-only teaser) a tap-to-retry failure row. Shared by
/// `ItineraryTabView`'s `importTeaser` (only visible while the itinerary is
/// empty) and `ShareTripView`'s persistent `importCard` (visible any time,
/// alongside the share-link/invite-link copyable tokens) — extracted here so
/// the address stays discoverable once the itinerary has items.
struct ImportAddressCard: View {
    /// Mirrors `TripFormView.Mode`'s associated-value-enum shape (this
    /// codebase's existing pattern for a small, closed set of view states)
    /// rather than an `address: String?` + `didFail: Bool` pair, so a caller
    /// can't represent the nonsensical "failed but here's an address" state.
    enum LoadState {
        case loading
        case loaded(String)
        case failed
    }

    let state: LoadState
    let onCopy: (String) -> Void
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.18))
                    .frame(width: 40, height: 40)
                    .overlay {
                        Image(systemName: "envelope.badge")
                            .foregroundStyle(Palette.amber)
                    }
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Email import")
                        .font(Typo.body(weight: .semibold))
                        .foregroundStyle(.white)
                    Text("We\u{2019}ll add it to your itinerary for you to review")
                        .font(Typo.body(11))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                Spacer(minLength: Spacing.sm)
            }

            switch state {
            case .loaded(let address):
                Button {
                    onCopy(address)
                } label: {
                    HStack(spacing: Spacing.xs) {
                        Text("Forward confirmations to")
                            .font(Typo.body(Typo.Size.caption))
                            .foregroundStyle(.white.opacity(0.72))
                        Text(address)
                            .font(Typo.mono(Typo.Size.caption))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.72))
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, Spacing.md)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Forward confirmations to \(address)")
                .accessibilityHint("Copies the import address")
            case .loading:
                HStack {
                    ProgressView().tint(.white)
                    Text("Loading your import address\u{2026}")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(.white.opacity(0.72))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .failed:
                Button(action: onRetry) {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.85))
                        Text("Couldn\u{2019}t load \u{2014} tap to retry")
                            .font(Typo.body(Typo.Size.caption))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .padding(.horizontal, Spacing.md)
                    .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Couldn\u{2019}t load your import address")
                .accessibilityHint("Tap to retry")
            }
        }
        .padding(Spacing.md)
        .background(Palette.indigo, in: RoundedRectangle(cornerRadius: Radii.card + 2, style: .continuous))
    }
}

#Preview {
    VStack {
        ImportAddressCard(state: .loaded("trip-abc123@import.tripto.navbytes.io"), onCopy: { _ in }, onRetry: {})
        ImportAddressCard(state: .loading, onCopy: { _ in }, onRetry: {})
        ImportAddressCard(state: .failed, onCopy: { _ in }, onRetry: {})
    }
    .padding(Spacing.xl)
    .background(Palette.paper)
}
