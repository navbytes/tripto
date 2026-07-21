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
            Text(text)
                .font(Typo.body())
                .foregroundStyle(Palette.ink)
                .textSelection(.enabled)
                .opacity(hasAppeared ? 1 : 0)
                .offset(y: hasAppeared ? 0 : 8)
                .onAppear {
                    withAnimation(Motion.m(Motion.gentle, reduceMotion: reduceMotion)) { hasAppeared = true }
                }
        case .failure:
            Text("Couldn\u{2019}t summarize this trip right now.")
                .font(Typo.body())
                .foregroundStyle(Palette.slate)
        }
    }

    private func generate() async {
        AccessibilityNotification.Announcement("Summarizing your trip\u{2026}").post()
        let context = TripPromptContext.render(trip: trip, memberNames: memberNames, items: items)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            switch await OnDeviceExtractor.summarizeTrip(context: context) {
            case .success(let text):
                state = .success(text)
                AccessibilityNotification.Announcement(text).post()
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
