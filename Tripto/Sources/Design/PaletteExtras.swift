import SwiftUI

// Hand-written companions to the generated `Palette` (Tokens.swift). Kept in a
// separate file so `gen_tokens.py` never clobbers them.
public extension Palette {
    /// Foreground for text/glyphs sitting on an amber fill. White-on-amber
    /// measures ~2.4:1 (fails WCAG AA and even the 3:1 large-text bar — flagged
    /// in the persona dry-run); this dark espresso is ~7:1 on `Palette.amber`.
    /// Fixed (not theme-adaptive) because the amber fill is the same in both
    /// light and dark, so its foreground must be too.
    static let onAmber = Color(hex: "#241505")

    /// Warning/rejection treatment — `SyncIssueBanner`'s "couldn't save"
    /// notice (FIX #1). Deliberately a different hue from `amber`/`amberSoft`
    /// (the "offline, will retry on its own" banner) so a permanently-failed
    /// write reads as more urgent than a temporary connectivity blip.
    /// Adaptive like the generated palette's own `dynamicColor` helper in
    /// Tokens.swift — recreated locally since that helper is file-private
    /// there, not exported for hand-written companions to reuse.
    static let rose = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(hex: "#E28A78")
            : UIColor(hex: "#B23B2E")
    })
    static let roseSoft = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(hex: "#B23B2E", alpha: 0.22)
            : UIColor(hex: "#F6E1DE")
    })

    /// Amber used as small text ink (eyebrows/labels), not the amber fill
    /// itself. BUILD_PLAN §6.1 positions amber as an accent/CTA color — at
    /// the generated `Palette.amber`'s light-mode hex it measures ~2.4:1 on
    /// `Palette.elevated`, which fails as fine-print ink. This darkened
    /// light variant is ~5.3:1 on `#FFFFFF`; dark mode keeps the existing
    /// amber look (~7:1 on `Palette.elevated`'s dark hex), so only light
    /// mode actually changes.
    static let amberInk = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(hex: "#E8955A")
            : UIColor(hex: "#A25A24")
    })

    /// `TripCard`'s glass pill fill (status pill, "Waiting to sync") — the
    /// mockup's `.white.opacity(0.22)` measured under WCAG AA on the
    /// lightest cover gradient stop (UX audit finding 3). Composited over
    /// dusk's lightest stop (#E8955A) this black-38% yields ~#905C38, ~5.5:1
    /// against the pill's white caption text (passes the 4.5:1 bar); moss's
    /// stop (#6E9E7E) composites to ~6.8:1 and the dark indigo/plum ends to
    /// ~16:1 — every gradient clears AA with the same single fill. Fixed
    /// (not theme-adaptive) because the cover gradients themselves don't
    /// change between light and dark, same rationale as `onAmber` above.
    static let coverPillFill = Color.black.opacity(0.38)
}
