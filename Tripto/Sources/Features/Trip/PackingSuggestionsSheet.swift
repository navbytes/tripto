import SwiftUI

/// "Suggest a starting list" (PLAN.md ai-garnish): on-device-only packing
/// suggestions, triggered from `PackingListView`'s header affordance (an
/// existing list) or its empty-state CTA (no list yet) — both call sites
/// gate on `OnDeviceExtractor.isAvailable` themselves, so (like
/// `CatchMeUpSheet`) this sheet never renders an "unavailable" state of its
/// own, only loading/vetting/failure once it's already showing. No cloud
/// fallback (PLAN.md).
///
/// Same "sheet is a dumb form, caller owns the writes" split
/// `PasteImportSheet`/`PackingItemFormSheet` already use: this never calls
/// `PackingItem.insert` itself — confirmed rows go back to the caller via
/// `onConfirm`, the exact `[(label:groupKey:)]` shape
/// `PasteImportSheet.onPackingConfirmed` already hands its own caller.
/// Suggestions are NEVER auto-inserted; every row starts pre-checked but
/// must clear `onConfirm`'s tap to become a real `PackingItem`.
struct PackingSuggestionsSheet: View {
    let trip: Trip
    let memberNames: [String]
    let items: [ItineraryItem]
    let existingLabels: [String]
    let onConfirm: ([(label: String, groupKey: PackingGroupKey)]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var state: GenerationState = .loading
    @State private var candidates: [PackingCandidate] = []

    private enum GenerationState {
        case loading
        case ready
        case failure
    }

    /// Nit (mirrors `PasteImportSheet.toAddCandidates`): a candidate edited
    /// down to an empty/whitespace-only label is dropped here rather than
    /// hand it to `onConfirm`, where `PackingItem.insert`'s own empty-label
    /// guard would silently no-op it while the confirm button's own count
    /// still claimed it'd be added.
    private var toAddCandidates: [(label: String, groupKey: PackingGroupKey)] {
        candidates
            .filter(\.isChecked)
            .compactMap { candidate in
                let trimmed = candidate.label.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (label: trimmed, groupKey: candidate.groupKey)
            }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeader(title: "Suggested packing items", onCancel: { dismiss() })
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        content
                    }
                    .padding(Spacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .background(Palette.paper)
            .toolbar(.hidden, for: .navigationBar)
        }
        .task { await generate() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            loadingView
        case .failure:
            Text("Couldn\u{2019}t suggest packing items right now.")
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
        case .ready:
            readyView
        }
    }

    private var loadingView: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
            Text("Suggesting packing items\u{2026}")
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xxl)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var readyView: some View {
        if candidates.isEmpty {
            Text("Nothing new to suggest \u{2014} your packing list already covers the essentials.")
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
        } else {
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Uncheck anything you don\u{2019}t want to add.")
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                VStack(spacing: Spacing.sm) {
                    ForEach($candidates) { $candidate in
                        PackingCandidateRow(candidate: $candidate)
                    }
                }
                confirmButton
            }
        }
    }

    private var confirmButton: some View {
        Button {
            onConfirm(toAddCandidates)
            dismiss()
        } label: {
            Text("Add \(toAddCandidates.count) item\(toAddCandidates.count == 1 ? "" : "s")")
                .font(Typo.body(weight: .semibold))
                .frame(maxWidth: .infinity)
                .foregroundStyle(toAddCandidates.isEmpty ? Palette.slate : Palette.onAmber)
                .padding(.vertical, Spacing.md)
                .background(
                    toAddCandidates.isEmpty ? Palette.mist : Palette.amber,
                    in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(toAddCandidates.isEmpty)
    }

    private func generate() async {
        AccessibilityNotification.Announcement("Suggesting packing items\u{2026}").post()
        let context = TripPromptContext.render(
            trip: trip, memberNames: memberNames, items: items, existingPackingLabels: existingLabels
        )
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch await OnDeviceExtractor.suggestPacking(context: context) {
            case .success(let raw):
                let mapped = PackingSuggestions.dedupe(
                    PackingSuggestions.candidates(from: raw), existingLabels: existingLabels
                )
                candidates = mapped
                state = .ready
                AccessibilityNotification.Announcement(
                    mapped.isEmpty
                        ? "Nothing new to suggest."
                        : "\(mapped.count) suggested item\(mapped.count == 1 ? "" : "s") ready to review."
                ).post()
            case .failure:
                state = .failure
                AccessibilityNotification.Announcement("Couldn\u{2019}t suggest packing items right now.").post()
            }
            return
        }
        #endif
        // Unreachable in practice — both trigger points are hidden unless
        // `OnDeviceExtractor.isAvailable` (`PackingListView.isOnDeviceAvailable`),
        // mirroring `PasteImportSheet.submitOnDevice()`'s own "kept as a
        // safe fallback rather than an assertion" reasoning.
        state = .failure
    }
}
