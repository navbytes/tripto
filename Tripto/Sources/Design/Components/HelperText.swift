import SwiftUI

/// The app-wide small-print helper-text treatment (e.g. "This is the big
/// title on your trip card.", "Leave everyone unselected..."). Factored into
/// one modifier so the look can't drift per call site (UX audit finding 3) —
/// every helper caption in the app used to hand-roll `.font(Typo.body(9.5))`
/// + `Palette.slate.opacity(0.8))`, an off-scale size paired with a
/// contrast-failing opacity: at 9.5pt that combination measured ~3.2:1 on
/// paper, below WCAG AA's 4.5:1 body-text bar. `Typo.Size.helper` (11pt) is
/// now a real token on the type scale, and full-opacity slate at 11pt clears
/// ~4.6:1.
extension View {
    func helperTextStyle() -> some View {
        font(Typo.body(Typo.Size.helper))
            .foregroundStyle(Palette.slate)
    }
}
