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
    ///
    /// A5 (`docs/BACKLOG.md`) / Apple Guideline 5.1.2(i): `.needsConsent` is
    /// the pre-consent state — a caller renders it instead of `.loading`
    /// whenever `EmailImportConsent.fetchDecision()` (`TripImportAddress
    /// .swift`) isn't `.fetchImmediately`, i.e. it never even calls
    /// `TripImportAddress.fetch` yet. Deliberately not "`.loading` + a
    /// separate `needsConsent: Bool`" for the same reason the other three
    /// cases are a closed enum, not flags: a caller can't represent
    /// "needs consent but also currently loading."
    enum LoadState {
        case needsConsent
        case loading
        case loaded(String)
        case failed
    }

    let state: LoadState
    let onCopy: (String) -> Void
    let onRetry: () -> Void
    /// A5: called when the user taps "Continue" on the consent dialog below
    /// — the caller's job (not this card's) is to record consent
    /// (`EmailImportConsent.grant()`) and then actually fetch, mirroring
    /// `onRetry`'s "the card only reports the tap, the caller owns the
    /// state transition" split. Never called for "Not now" (the dialog's own
    /// cancel action, an empty closure) — the card just stays in
    /// `.needsConsent`, re-tappable.
    let onConsentGranted: () -> Void

    /// A5: local to this card, not the caller — same reasoning as
    /// `PasteImportSheet`'s own consent-dialog booleans, just scoped one
    /// level lower since both `ItineraryTabView` and `ShareTripView` share
    /// this one card/dialog instead of each duplicating the copy.
    @State private var isPresentingConsentDialog = false

    @ScaledMetric(relativeTo: .caption) private var copyIconSize: CGFloat = 11
    @ScaledMetric(relativeTo: .caption) private var retryIconSize: CGFloat = 12

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
            case .needsConsent:
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    // Compliance (Nov-2025 Guideline 5.1.2(i) — NAMED
                    // pre-transmission disclosure): "OpenAI" must change if
                    // backend's LLM_MODEL secret changes
                    // (~/repos/backend/projects/tripto/RUNBOOK.md §5) —
                    // ingest-text and ingest-email share that ONE secret, so
                    // a provider switch means updating this string AND both
                    // dialog copies below/in PasteImportSheet.swift together.
                    Text("Forwarded emails are sent to OpenAI, routed through our Cloudflare gateway, to find your bookings.")
                        .font(Typo.body(Typo.Size.caption))
                        .foregroundStyle(.white.opacity(0.72))
                        .fixedSize(horizontal: false, vertical: true)
                    Button {
                        isPresentingConsentDialog = true
                    } label: {
                        Text("Show email address")
                            .font(Typo.body(weight: .semibold))
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .foregroundStyle(.white)
                            .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Show email address")
                    .accessibilityHint("Asks to allow forwarded emails to be processed by AI, then shows the address")
                }
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
                            .font(.system(size: copyIconSize, weight: .semibold))
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
                            .font(.system(size: retryIconSize, weight: .semibold))
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
        // A5 (`docs/BACKLOG.md`) / Apple Guideline 5.1.2(i): explicit,
        // affirmative permission before the address is revealed and
        // forwarded emails start being processed by the third-party AI —
        // lives on the card (not duplicated in each caller) since both
        // `ItineraryTabView` and `ShareTripView` show this exact card/copy.
        // Native `confirmationDialog`, same idiom as `PasteImportSheet`'s
        // paste-import consent dialog: system chrome, so Dynamic Type,
        // VoiceOver, Reduce Motion, and the 44pt tap-target floor all come
        // for free. Only "Continue" reports the grant; "Not now" (the
        // dialog's own cancel action) leaves the card in `.needsConsent`,
        // re-tappable.
        .confirmationDialog(
            "Email your bookings to this trip",
            isPresented: $isPresentingConsentDialog,
            titleVisibility: .visible
        ) {
            Button("Continue") {
                onConsentGranted()
            }
            Button("Not now", role: .cancel) {}
        } message: {
            // Compliance: same provider as the explainer above — keep both
            // (and PasteImportSheet's own consent copy) in sync with
            // backend's LLM_MODEL.
            Text(
                "Forwarded emails are processed by OpenAI, routed through our Cloudflare gateway, to extract bookings. "
                    + "The raw email is kept for up to 7 days, then deleted. Confirmation codes stay private to trip members."
            )
        }
    }
}

#Preview {
    VStack {
        ImportAddressCard(state: .needsConsent, onCopy: { _ in }, onRetry: {}, onConsentGranted: {})
        ImportAddressCard(state: .loaded("trip-abc123@import.tripto.navbytes.io"), onCopy: { _ in }, onRetry: {}, onConsentGranted: {})
        ImportAddressCard(state: .loading, onCopy: { _ in }, onRetry: {}, onConsentGranted: {})
        ImportAddressCard(state: .failed, onCopy: { _ in }, onRetry: {}, onConsentGranted: {})
    }
    .padding(Spacing.xl)
    .background(Palette.paper)
}
