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

    /// Amber-soft tint for the "First up"/"Today" eyebrow labels
    /// (`FirstUpStrip`/`TodayPanelView`) — the mockup's `.lbl` sets
    /// `color: var(--amber-soft)`, not plain white (P5 fix-round item 9).
    /// Reuses `amberSoft`'s own light-mode hex rather than inventing a new
    /// number, but as a fixed (not theme-adaptive) constant: `amberSoft`
    /// itself turns into a 22%-alpha wash in dark mode, which would render
    /// this text near-invisible, and the wrong surface anyway — like
    /// `coverPillFill` above, the cover gradient behind it doesn't change
    /// with the system appearance. Computed against the same worst case as
    /// that token's own audit (dusk's lightest stop composited under
    /// `coverPillFill`), this measures ~4.74:1 (moss ~5.77:1, plum
    /// ~7.61:1) — all clear AA's 4.5:1 bar. The mockup's own literal
    /// `--amber-soft` (#F6C48A, more saturated) only reaches ~3.49:1 on
    /// dusk, so it was rejected. Used at full opacity, not stacked under an
    /// extra `.opacity(0.85)` the way the white eyebrow text previously
    /// was — that dimming would drop dusk to ~3.93:1, under the bar.
    static let coverPillAmberText = Color(hex: "#FBEADB")

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

    /// CTA "glow" shadow tint for a primary amber-filled button in its
    /// enabled state — P7b craft audit: three near-duplicate ad-hoc
    /// `Palette.amber.opacity(...)` shadow literals with no shared name
    /// (`TripFormView`'s "Create trip" and `AddItemSheet`'s "Add" at `.45`,
    /// `Fab`'s add button at `.55`), most visible as a halo in dark mode —
    /// unlike `shadow` above, this color itself doesn't change with the
    /// theme (same fixed hex as `Palette.amber` in both), but a warm glow
    /// genuinely reads as far more prominent against a dark backdrop than
    /// against `Palette.paper`'s light-mode cream, which is what the finding
    /// actually caught. Named here as the one vocabulary for that effect,
    /// `Color`-only like `shadow` (callers keep supplying their own
    /// `.opacity(...)`/radius/y). Not yet adopted at those three call sites
    /// — outside this pass's file scope (Home/PaletteExtras only); switch
    /// them to this token instead of a fourth literal.
    static let amberGlow = amber
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

/// UX P6.5 (docs/UX_REDESIGN_ROADMAP.md; `.claude/company/ux-redesign/
/// DECISIONS.md` 2026-07-15): many more trip covers via random generation,
/// on top of (not replacing) the three curated `CoverGradient` tokens.
/// `Trip.cover_gradient` is unconstrained `text` server-side — `not null
/// default 'dusk'`, no `CHECK` (unlike e.g. `trip_type`, which has one) —
/// so a structured non-hex key is a safe, schema-compatible thing to store;
/// "never a raw hex value" (the column's own DB comment) is honored by
/// encoding hues, not colors.
///
/// Format: `"gen:v1:<hue1>,<hue2>"` — two integers, 0...359 degrees, for the
/// gradient's first two stops. Versioned so a future format change adds a
/// case rather than silently reinterpreting old keys. Everything else
/// (saturation/brightness bands, the third stop, direction) is fixed,
/// derived from the three curated gradients' own measured HSB (via
/// `colorsys`, hue in degrees/sat+brightness in percent) so a generated
/// cover always reads as this app's own "dusk departure" aesthetic, never
/// an arbitrary color:
///   dusk (25,61,91) / (9,55,79) / (237,45,32)
///   plum (278,32,62) / (216,49,69) / (237,43,18)
///   moss (140,30,62) / (216,49,69) / (237,45,32)
/// (stop1 / stop2 / stop3, in gradient order). Stop3 is nearly one fixed
/// dark-indigo tone across all three (hue ~237°, brightness 18-32%) —
/// reused verbatim as `Palette.indigo` (`#2D2F52`, an exact match for 2 of
/// the 3) rather than banded/randomized.
///
/// `CoverGradient.from(key:)` (Tokens.swift, generated) calls `decode`
/// for any key that isn't one of the curated names — this is the ONE seam
/// every render site (`TripCard`, hero, "been" thumbnails, the widgets)
/// already goes through, so none of them need to know this format exists.
public enum CoverGradientGenerator {
    static let prefix = "gen:v1:"

    /// Stop1 (the accent corner) — observed range across the curated set
    /// is S 30-61%, V 62-91%. Upper V bound (91%) is the cap: dusk's own
    /// accent stop (`#E8955A`), the brightest stop across the curated set
    /// AND the exact "lightest stop" `Palette.coverPillFill`'s own
    /// contrast math already treats as its worst case. A generated stop1
    /// is therefore provably never brighter than a color the existing
    /// scrim/pill contrast audit already covers — no near-white tops.
    static let stop1Saturation: ClosedRange<Double> = 0.30...0.61
    static let stop1Brightness: ClosedRange<Double> = 0.62...0.91

    /// Stop2 (the middle transition) — observed S 49-55%, V 69-79%; 79% is
    /// dusk's own stop2 brightness, the curated set's max there.
    static let stop2Saturation: ClosedRange<Double> = 0.49...0.55
    static let stop2Brightness: ClosedRange<Double> = 0.69...0.79

    /// A fresh key for the Shuffle button / a new trip's cover — `seed` is
    /// expected to be real entropy at the call site (`UInt64.random(in:)`);
    /// this function itself stays a deterministic, testable function of
    /// it, same "seed in, same key out" contract as
    /// `TripFormView.seededGradientKey`. The two hues come from different
    /// slices of the one seed rather than two independent rolls — good
    /// enough for a decorative gradient, and keeps this a one-argument
    /// pure function.
    public static func generate(seed: UInt64) -> String {
        let hue1 = Int(seed % 360)
        let hue2 = Int((seed / 360) % 360)
        return "\(prefix)\(hue1),\(hue2)"
    }

    /// Decodes a `"gen:v1:<hue1>,<hue2>"` key into its gradient — `nil` for
    /// anything else (no prefix, wrong shape, non-numeric or out-of-range
    /// hues), so `CoverGradient.from(key:)` can fall back to the default
    /// exactly like an unrecognized curated key already does.
    public static func decode(_ key: String?) -> LinearGradient? {
        guard let (hue1, hue2) = parsedHues(key) else { return nil }
        return LinearGradient(
            colors: [
                stopColor(hue: hue1, saturation: stop1Saturation, brightness: stop1Brightness),
                stopColor(hue: hue2, saturation: stop2Saturation, brightness: stop2Brightness),
                Palette.indigo
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// `"gen:v1:<hue1>,<hue2>"` -> both hues (each 0...359), case-
    /// insensitive; `nil` for anything malformed. The one parse seam
    /// `decode` relies on for its own fallback — `internal` (not
    /// `private`) so a test can pin "malformed -> nil" directly against
    /// it, same access level as the rest of this generator's internals.
    static func parsedHues(_ key: String?) -> (Int, Int)? {
        guard let lowered = key?.lowercased(), lowered.hasPrefix(prefix) else { return nil }
        let parts = lowered.dropFirst(prefix.count).split(separator: ",", omittingEmptySubsequences: false)
        guard parts.count == 2,
            let hue1 = Int(parts[0]), let hue2 = Int(parts[1]),
            (0...359).contains(hue1), (0...359).contains(hue2)
        else { return nil }
        return (hue1, hue2)
    }

    /// One hue banded into a fixed saturation/brightness range — the hue's
    /// own position in its 0...359 span doubles as the band position
    /// (`t`), so a single random hue drives both "which color" and "how
    /// light/saturated," rather than spending extra seed bits on a second
    /// independent roll for each stop.
    static func stopColor(hue: Int, saturation: ClosedRange<Double>, brightness: ClosedRange<Double>) -> Color {
        let t = Double(hue) / 359
        return Color(hue: Double(hue) / 360, saturation: lerp(saturation, t), brightness: lerp(brightness, t))
    }

    static func lerp(_ range: ClosedRange<Double>, _ t: Double) -> Double {
        range.lowerBound + (range.upperBound - range.lowerBound) * t
    }
}
