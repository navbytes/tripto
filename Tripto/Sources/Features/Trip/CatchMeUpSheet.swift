import SwiftUI

/// "Catch me up" (PLAN.md ai-garnish): an on-device-only trip summary,
/// triggered from the hero's overflow menu next to "Add Trip to Calendar"
/// (`HeroCollapse.swift`'s `TripHeroView`) — that menu item only exists at
/// all when `OnDeviceExtractor.isAvailable`, so this sheet never needs an
/// "unavailable" state of its own, only loading/success/failure once it's
/// already showing. No cloud fallback (PLAN.md) — a failure here is just a
/// failure, never a second attempt over the network.
struct CatchMeUpSheet: View {
    let trip: Trip
    let memberNames: [String]
    let items: [ItineraryItem]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var state: GenerationState = .loading
    /// One-shot arrival reveal for the generated text, same recipe as
    /// `EmptyStateArt`'s own intro (`hasAppeared` flipped once inside
    /// `Motion.m(Motion.gentle, ...)`) — instant under Reduce Motion.
    @State private var hasAppeared = false

    private enum GenerationState {
        case loading
        case success(String)
        case failure
    }

    /// UX audit: the summary is a model's read of the trip, not a re-check
    /// of it — this caption is what keeps it from reading as verified
    /// itinerary fact (§6.6 voice). Shared by the visible caption and the
    /// VoiceOver completion announcement below so the two can't drift.
    private static let disclosureCaption =
        "Summarized on this iPhone from your saved plans. Check the itinerary for exact times."

    var body: some View {
        NavigationStack {
            ScrollView {
                content
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Spacing.xl)
            }
            .background(Palette.paper)
            .navigationTitle("Catch me up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await generate() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            VStack(spacing: Spacing.md) {
                ProgressView()
                Text("Summarizing your trip\u{2026}")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, Spacing.xxl)
            // One combined VoiceOver stop, same recipe as
            // `PasteImportSheet`'s own batch-progress row.
            .accessibilityElement(children: .combine)
        case .success(let text):
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text(text)
                    .font(Typo.body())
                    .foregroundStyle(Palette.ink)
                    .textSelection(.enabled)
                // UX audit: on-brand disclosure caption — the summary must
                // never read as verified itinerary fact.
                Text(Self.disclosureCaption)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
            }
            .opacity(hasAppeared ? 1 : 0)
            .offset(y: hasAppeared ? 0 : 8)
            .onAppear {
                withAnimation(Motion.m(Motion.gentle, reduceMotion: reduceMotion)) { hasAppeared = true }
            }
        case .failure:
            // UX audit: no dead-end failure (§6.6) — "Try again" re-runs
            // the same `generate()` the sheet already calls on appear.
            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Couldn\u{2019}t summarize this trip right now.")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)
                Button("Try again") { Task { await generate() } }
                    .buttonStyle(.primaryCapsule)
            }
        }
    }

    private func generate() async {
        // Re-entrant: also the "Try again" tap on a prior failure, which
        // needs the loading state (and its own spinner/announcement) back
        // rather than jumping straight from failure copy to success.
        state = .loading
        AccessibilityNotification.Announcement("Summarizing your trip\u{2026}").post()
        let context = TripPromptContext.render(trip: trip, memberNames: memberNames, items: items)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch await OnDeviceExtractor.summarizeTrip(context: context) {
            case .success(let text):
                state = .success(text)
                // Folds the disclosure caption into the same announcement
                // so a VoiceOver user hears it without swiping further.
                AccessibilityNotification.Announcement("\(text) \(Self.disclosureCaption)").post()
            case .failure:
                state = .failure
                AccessibilityNotification.Announcement("Couldn\u{2019}t summarize this trip right now.").post()
            }
            return
        }
        #endif
        // Unreachable in practice — the triggering menu item is hidden
        // unless `OnDeviceExtractor.isAvailable` (`TripHeroView
        // .isOnDeviceAvailable`), mirroring `PasteImportSheet
        // .submitOnDevice()`'s own "kept as a safe fallback rather than an
        // assertion" reasoning for the impossible branch.
        state = .failure
    }
}
