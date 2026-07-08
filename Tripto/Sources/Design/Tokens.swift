// GENERATED from design/tokens.json — do not edit.
// Regenerate with: python3 scripts/gen_tokens.py
//
// Tripto design tokens compiled to Swift constants (BUILD_PLAN.md §6,
// §3.6 "design tokens as data"). One source (tokens.json), one
// generated artifact, committed together so the app always builds
// without a codegen step.

import SwiftUI
import CoreText

// MARK: - Hex color plumbing

extension UIColor {
    /// Creates a color from a "#RRGGBB" hex string. Malformed input falls
    /// back to opaque black rather than crashing.
    convenience init(hex: String, alpha: CGFloat = 1) {
        let cleaned = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r = CGFloat((value & 0xFF0000) >> 16) / 255
        let g = CGFloat((value & 0x00FF00) >> 8) / 255
        let b = CGFloat(value & 0x0000FF) / 255
        self.init(red: r, green: g, blue: b, alpha: alpha)
    }
}

public extension Color {
    /// Creates a fixed (non-adaptive) color from a "#RRGGBB" hex string.
    init(hex: String, alpha: CGFloat = 1) {
        self.init(UIColor(hex: hex, alpha: alpha))
    }
}

/// Builds a `Color` that adapts between light and dark using a `UIColor`
/// dynamic provider — the palette follows the system appearance
/// automatically, with no call-site branching on `colorScheme`.
private func dynamicColor(
    lightHex: String,
    lightAlpha: CGFloat = 1,
    darkHex: String,
    darkAlpha: CGFloat = 1
) -> Color {
    Color(UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(hex: darkHex, alpha: darkAlpha)
            : UIColor(hex: lightHex, alpha: lightAlpha)
    })
}

// MARK: - Palette

/// "Dusk departure" palette (BUILD_PLAN.md §6.1). Each color adapts
/// light/dark automatically — never branch on `colorScheme` to pick a
/// Palette member, just use it.
public enum Palette {
    public static let ink = dynamicColor(lightHex: "#1A1B2E", darkHex: "#F2F1F7")
    public static let indigo = dynamicColor(lightHex: "#2D2F52", darkHex: "#2D2F52")
    public static let slate = dynamicColor(lightHex: "#6B6E8F", darkHex: "#A5A7C0")
    public static let mist = dynamicColor(lightHex: "#EEEDF4", darkHex: "#2A2B40")
    public static let paper = dynamicColor(lightHex: "#FBFAF7", darkHex: "#141522")
    public static let elevated = dynamicColor(lightHex: "#FFFFFF", darkHex: "#1C1D30")
    public static let amber = dynamicColor(lightHex: "#E8955A", darkHex: "#E8955A")
    public static let amberSoft = dynamicColor(lightHex: "#FBEADB", darkHex: "#E8955A", darkAlpha: 0.22)
}

// MARK: - Category colors

/// Semantic itinerary-category colors (BUILD_PLAN.md §6.1). These are
/// fixed brand assignments — flight is always sky, hotel always amber,
/// activity always moss, food always plum. Do not reassign per trip.
public enum CategoryColor {
    public struct Pair {
        public let fg: Color
        public let soft: Color
    }

    public enum Key: String, CaseIterable {
        case flight
        case hotel
        case activity
        case food
        case transport
    }

    public static let flight = Pair(
        fg: dynamicColor(lightHex: "#5B7DB1", darkHex: "#5B7DB1"),
        soft: dynamicColor(lightHex: "#E3EAF3", darkHex: "#5B7DB1", darkAlpha: 0.22)
    )

    public static let hotel = Pair(
        fg: dynamicColor(lightHex: "#E8955A", darkHex: "#E8955A"),
        soft: dynamicColor(lightHex: "#FBEADB", darkHex: "#E8955A", darkAlpha: 0.22)
    )

    public static let activity = Pair(
        fg: dynamicColor(lightHex: "#6E9E7E", darkHex: "#6E9E7E"),
        soft: dynamicColor(lightHex: "#E3EEE6", darkHex: "#6E9E7E", darkAlpha: 0.22)
    )

    public static let food = Pair(
        fg: dynamicColor(lightHex: "#8B6B9E", darkHex: "#8B6B9E"),
        soft: dynamicColor(lightHex: "#EDE5F1", darkHex: "#8B6B9E", darkAlpha: 0.22)
    )

    public static let transport = Pair(
        fg: dynamicColor(lightHex: "#4F8A87", darkHex: "#4F8A87"),
        soft: dynamicColor(lightHex: "#E0EBEA", darkHex: "#4F8A87", darkAlpha: 0.22)
    )

    /// Looks up a category pair by key; unknown keys fall back to `flight`
    /// rather than crashing (defensive against future/unknown category
    /// strings arriving from the backend).
    public static func pair(for key: Key) -> Pair {
        switch key {
        case .flight: return flight
        case .hotel: return hotel
        case .activity: return activity
        case .food: return food
        case .transport: return transport
        }
    }
}

// MARK: - Cover gradients

/// Trip cover gradients (BUILD_PLAN.md §6.1). Referenced by key from
/// `Trip.cover_gradient` — never inline raw hex stops in a view.
public enum CoverGradient {
    public static let dusk = LinearGradient(
        colors: [Color(hex: "#E8955A"), Color(hex: "#C96B5B"), Color(hex: "#2D2F52")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let plum = LinearGradient(
        colors: [Color(hex: "#8B6B9E"), Color(hex: "#5B7DB1"), Color(hex: "#1A1B2E")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let moss = LinearGradient(
        colors: [Color(hex: "#6E9E7E"), Color(hex: "#5B7DB1"), Color(hex: "#2D2F52")],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    /// Alias: "default" -> "dusk"
    public static let defaultGradient = dusk

    /// Resolves a `cover_gradient` token key to a gradient, falling back to
    /// the default when the key is missing or not recognized.
    public static func from(key: String?) -> LinearGradient {
        switch key?.lowercased() {
        case "dusk": return dusk
        case "plum": return plum
        case "moss": return moss
        case "default": return defaultGradient
        default: return defaultGradient
        }
    }
}

// MARK: - Spacing

/// Spacing scale (BUILD_PLAN.md §6). Use these instead of raw point
/// values so the rhythm of the app stays consistent.
public enum Spacing {
    public static let xxs: CGFloat = 2
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 8
    public static let md: CGFloat = 12
    public static let lg: CGFloat = 16
    public static let xl: CGFloat = 22
    public static let xxl: CGFloat = 32
    /// The raw scale, smallest to largest: [2, 4, 8, 12, 16, 22, 32]
    public static let scale: [CGFloat] = [2, 4, 8, 12, 16, 22, 32]
}

// MARK: - Radii

public enum Radii {
    public static let card: CGFloat = 16
    public static let sheet: CGFloat = 22
    public static let pill: CGFloat = 999
    public static let cover: CGFloat = 22
}

// MARK: - Typography

/// Type scale (BUILD_PLAN.md §6.2): Fraunces for display/titles, Sofia
/// Sans for body/UI, monospace for confirmation codes. Fonts are bundled
/// (Tripto/Resources/Fonts) and registered via UIAppFonts — see
/// FontCheck for a DEBUG-time sanity check that they actually loaded.
public enum Typo {
    /// Named sizes from the type scale. Pass these to `display`/`body`,
    /// or any custom size.
    public enum Size {
        public static let display: CGFloat = 30
        public static let displayLineHeight: CGFloat = 34
        public static let title: CGFloat = 20
        public static let body: CGFloat = 14.5
        public static let caption: CGFloat = 12.5
    }

    private static let displayFamilyKeyword = "Fraunces"
    private static let bodyFamilyKeyword = "Sofia Sans"

    /// Display type — Fraunces. Used with restraint: city names and
    /// screen titles (BUILD_PLAN.md §6.2). Weights available: 500, 600.
    public static func display(_ size: CGFloat = Size.display, weight: Font.Weight = .semibold) -> Font {
        variableFont(familyKeyword: displayFamilyKeyword, size: size, weight: weight)
    }

    /// Body/UI type — Sofia Sans. Weights available: 400, 500, 600, 700.
    public static func body(_ size: CGFloat = Size.body, weight: Font.Weight = .regular) -> Font {
        variableFont(familyKeyword: bodyFamilyKeyword, size: size, weight: weight)
    }

    /// Data/confirmation-code type — system monospace (BUILD_PLAN.md §6.2).
    public static func mono(_ size: CGFloat = Size.body) -> Font {
        .system(size: size, design: .monospaced)
    }
}

// MARK: - Variable font plumbing

/// Bundled Fraunces/Sofia Sans are variable TTFs. Plain `Font.custom` only
/// ever resolves to a font's *default* instance, so dialing a specific
/// weight needs the `wght` variation axis set directly on a
/// `UIFontDescriptor` — the `.weight()` SwiftUI modifier does not
/// reliably move a custom variable font's axis. See RESEARCH_FINDINGS.md
/// item 4 / plan amendment #10.
private enum VariableFontAxis {
    /// Decimal form of the four-char axis tag 'wght'.
    static let weight = 2003265652
}

private func variableFont(familyKeyword: String, size: CGFloat, weight: Font.Weight) -> Font {
    guard
        let family = UIFont.familyNames.first(where: { $0.localizedCaseInsensitiveContains(familyKeyword) }),
        let postscriptName = UIFont.fontNames(forFamilyName: family).first
    else {
        // Font not registered (e.g. a plain SwiftUI preview target) — degrade
        // to the system font rather than crashing.
        return .system(size: size, weight: weight)
    }
    let variationAttribute = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)
    let descriptor = UIFontDescriptor(name: postscriptName, size: size)
        .addingAttributes([variationAttribute: [VariableFontAxis.weight: weight.variableAxisValue]])
    return Font(UIFont(descriptor: descriptor, size: size))
}

private extension Font.Weight {
    /// Maps SwiftUI's semantic weight cases to a `wght` axis coordinate.
    var variableAxisValue: CGFloat {
        switch self {
        case .ultraLight: return 100
        case .thin: return 200
        case .light: return 300
        case .regular: return 400
        case .medium: return 500
        case .semibold: return 600
        case .bold: return 700
        case .heavy: return 800
        case .black: return 900
        default: return 400
        }
    }
}
