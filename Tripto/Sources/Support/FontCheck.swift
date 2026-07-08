#if DEBUG
import SwiftUI
import UIKit

/// DEBUG-only sanity check that the bundled Fraunces/Sofia Sans variable
/// fonts actually registered via `UIAppFonts` in Info.plist. Mounted
/// invisibly by `RootView` and prints to the console once on appear — there
/// is no user-facing UI, the console output is the whole point.
///
/// RESEARCH_FINDINGS.md flags bundled variable fonts as a real risk area
/// (custom SOFT/WONK axes, family-name quirks); this is the cheapest
/// possible tripwire if a future font swap silently breaks registration.
struct FontCheck: View {
    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear(perform: logRegisteredFonts)
    }

    private func logRegisteredFonts() {
        let families = UIFont.familyNames.filter {
            $0.localizedCaseInsensitiveContains("Fraunces") ||
                $0.localizedCaseInsensitiveContains("Sofia")
        }
        guard !families.isEmpty else {
            print("[FontCheck] no Fraunces/Sofia Sans families registered — check UIAppFonts in Info.plist")
            return
        }
        for family in families.sorted() {
            print("[FontCheck] \(family): \(UIFont.fontNames(forFamilyName: family))")
        }
    }
}
#endif
