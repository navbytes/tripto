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
    ///
    /// UX-audit finding 3 reuses this rather than adding a same-purpose
    /// `amberText` duplicate (read this file first, per the brief's own
    /// "must not collide with existing names"): light-mode `#A25A24` is
    /// ~5.0:1 on `Palette.paper` (`#FBFAF7`), and dark-mode `#E8955A` is
    /// ~7.7:1 on `Palette.paper`'s dark hex (`#141522`) — both clear the
    /// finding's ≥4.5:1 bar on paper as well as elevated. Backs
    /// `BookingDetailView`'s note Edit/Save, `AddItemFormSections`' "Same
    /// as pickup", and `PackingListView`'s "Show/Hide packed" + percent
    /// label — every inline (non-capsule) amber text action found in the
    /// audit's Features/Trip/** sweep. CTA-weight actions instead become
    /// filled `Palette.amber`/`Palette.onAmber` capsules (see
    /// `TripView.missingTripState`).
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

    /// Elevation/depth tint for `.shadow(color:...)` call sites (UX audit
    /// finding 5) — deliberately distinct from `ink`, which is
    /// text-semantic and flips to near-white in dark mode; using it as a
    /// shadow color there rendered card drops as a pale halo instead of a
    /// dark depth cue. This stays dark in both themes: light mode reuses
    /// the light-mode `ink` hex (so it renders pixel-identically to the
    /// pre-fix shadows), dark mode is pure black (a subtle dark drop on
    /// `Palette.elevated`'s dark paper, rather than a lit-up ink glow).
    /// Call sites keep supplying their own `.opacity(...)`.
    static let shadow = Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(hex: "#000000")
            : UIColor(hex: "#1A1B2E")
    })
}

// Hand-written companion to the generated `CoverGradient` (Tokens.swift).
// Kept here for the same reason as the `Palette` extras above — this file
// is never touched by `gen_tokens.py`.
public extension CoverGradient {
    /// `TripCard`'s bottom text scrim (UX audit finding 2) — the mockup lays
    /// white title/meta text straight over the cover gradient with nothing
    /// underneath it. Worst case is dusk's bottom-LEFT text position
    /// (~#DB835B under the title/meta block): plain white on that measures
    /// ~2.8:1, failing AA for the meta caption outright. This scrim is clear
    /// until 35% down (so it never dims the top-row status/pending pills —
    /// `coverPillFill`'s own top-edge contrast fix is unaffected) and ramps
    /// to 45%-black by the bottom edge. Composited at the meta row's depth
    /// (~84% down, effective black ~0.34) dusk's bottom-left stop yields
    /// ~5.3:1 for `.white.opacity(0.92)` caption text; at the title's depth
    /// (~72% down, effective ~0.26) it yields ~4.8:1 — clearing the 4.5:1 AA
    /// bar and the 3:1 large-text bar respectively. Plum and moss are darker
    /// at that corner already, so both only improve. Fixed (not
    /// theme-adaptive), same rationale as `coverPillFill`: cover gradients
    /// don't change between light and dark.
    static let textScrim = LinearGradient(
        stops: [
            .init(color: .clear, location: 0.35),
            .init(color: .black.opacity(0.45), location: 1.0)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}
