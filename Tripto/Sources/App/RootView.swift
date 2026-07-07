import SwiftUI

/// Shell root view. No navigation logic yet (M0 scaffolding only) — this
/// exists to visually prove the design tokens and bundled fonts render
/// correctly before any real screens are built.
struct RootView: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Palette.paper.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text("Your trips")
                    .font(Typo.display())
                    .foregroundStyle(Palette.ink)

                Text("Everyone's plans, one shared itinerary.")
                    .font(Typo.body())
                    .foregroundStyle(Palette.slate)

                PillLabel(text: "Design system online", tint: .amber)
                    .padding(.top, Spacing.sm)

                Spacer()
            }
            .padding(Spacing.xl)

            #if DEBUG
            FontCheck()
            #endif
        }
    }
}

#Preview {
    RootView()
}
