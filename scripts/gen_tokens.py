#!/usr/bin/env python3
"""Generate Tripto/Sources/Design/Tokens.swift from design/tokens.json.

Deterministic: the same tokens.json always produces byte-identical Swift
output. Stdlib only — no third-party dependencies required.

Usage:
    python3 scripts/gen_tokens.py

Do not hand-edit the generated Tokens.swift; edit design/tokens.json and
re-run this script instead.
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
TOKENS_JSON = REPO_ROOT / "design" / "tokens.json"
OUTPUT_SWIFT = REPO_ROOT / "Tripto" / "Sources" / "Design" / "Tokens.swift"

# wght (weight) variation axis tag, decimal form of the four-char code 'wght'.
WGHT_AXIS = 2_003_265_652

# Swift identifiers reserved by the language that can't be used bare as a
# `static let` name — wrap in backticks if a token key collides with one.
SWIFT_KEYWORDS = {
    "default", "class", "struct", "enum", "func", "var", "let", "in", "for",
    "if", "else", "switch", "case", "return", "import", "protocol",
    "extension", "public", "private", "internal", "static", "self", "Self",
}


def swift_identifier(name: str) -> str:
    """Return `name` unchanged unless it collides with a Swift keyword."""
    return f"`{name}`" if name in SWIFT_KEYWORDS else name


def fmt_number(value: float) -> str:
    """Format a JSON number as a Swift CGFloat literal (no trailing .0 noise
    beyond what's needed, but always at least one decimal so CGFloat infers
    correctly)."""
    if float(value).is_integer():
        return f"{int(value)}"
    return repr(float(value))


def color_expr(light: dict, dark: dict) -> str:
    """Build a `dynamicColor(...)` call expression from light/dark token
    entries of the shape {"hex": "#RRGGBB", "alpha": <optional float>}."""
    light_hex = light["hex"]
    dark_hex = dark["hex"]
    light_alpha = light.get("alpha", 1)
    dark_alpha = dark.get("alpha", 1)
    parts = [f'lightHex: "{light_hex}"']
    if light_alpha != 1:
        parts.append(f"lightAlpha: {fmt_number(light_alpha)}")
    parts.append(f'darkHex: "{dark_hex}"')
    if dark_alpha != 1:
        parts.append(f"darkAlpha: {fmt_number(dark_alpha)}")
    return f"dynamicColor({', '.join(parts)})"


def gen_header() -> list[str]:
    return [
        "// GENERATED from design/tokens.json — do not edit.",
        "// Regenerate with: python3 scripts/gen_tokens.py",
        "//",
        "// Tripto design tokens compiled to Swift constants (BUILD_PLAN.md §6,",
        "// §3.6 \"design tokens as data\"). One source (tokens.json), one",
        "// generated artifact, committed together so the app always builds",
        "// without a codegen step.",
        "",
        "import SwiftUI",
        "import CoreText",
        "",
    ]


def gen_dynamic_helpers() -> list[str]:
    return [
        "// MARK: - Hex color plumbing",
        "",
        "extension UIColor {",
        "    /// Creates a color from a \"#RRGGBB\" hex string. Malformed input falls",
        "    /// back to opaque black rather than crashing.",
        "    convenience init(hex: String, alpha: CGFloat = 1) {",
        "        let cleaned = hex.hasPrefix(\"#\") ? String(hex.dropFirst()) : hex",
        "        var value: UInt64 = 0",
        "        Scanner(string: cleaned).scanHexInt64(&value)",
        "        let r = CGFloat((value & 0xFF0000) >> 16) / 255",
        "        let g = CGFloat((value & 0x00FF00) >> 8) / 255",
        "        let b = CGFloat(value & 0x0000FF) / 255",
        "        self.init(red: r, green: g, blue: b, alpha: alpha)",
        "    }",
        "}",
        "",
        "public extension Color {",
        "    /// Creates a fixed (non-adaptive) color from a \"#RRGGBB\" hex string.",
        "    init(hex: String, alpha: CGFloat = 1) {",
        "        self.init(UIColor(hex: hex, alpha: alpha))",
        "    }",
        "}",
        "",
        "/// Builds a `Color` that adapts between light and dark using a `UIColor`",
        "/// dynamic provider — the palette follows the system appearance",
        "/// automatically, with no call-site branching on `colorScheme`.",
        "private func dynamicColor(",
        "    lightHex: String,",
        "    lightAlpha: CGFloat = 1,",
        "    darkHex: String,",
        "    darkAlpha: CGFloat = 1",
        ") -> Color {",
        "    Color(UIColor { traits in",
        "        traits.userInterfaceStyle == .dark",
        "            ? UIColor(hex: darkHex, alpha: darkAlpha)",
        "            : UIColor(hex: lightHex, alpha: lightAlpha)",
        "    })",
        "}",
        "",
    ]


def gen_palette(tokens: dict) -> list[str]:
    light = tokens["palette"]["light"]
    dark = tokens["palette"]["dark"]
    if light.keys() != dark.keys():
        sys.exit(
            "gen_tokens: palette.light and palette.dark must define the same "
            f"keys (light={sorted(light)}, dark={sorted(dark)})"
        )
    lines = [
        "// MARK: - Palette",
        "",
        "/// \"Dusk departure\" palette (BUILD_PLAN.md §6.1). Each color adapts",
        "/// light/dark automatically — never branch on `colorScheme` to pick a",
        "/// Palette member, just use it.",
        "public enum Palette {",
    ]
    for key, light_entry in light.items():
        dark_entry = dark[key]
        lines.append(f"    public static let {swift_identifier(key)} = {color_expr(light_entry, dark_entry)}")
    lines += ["}", ""]
    return lines


def gen_category_colors(tokens: dict) -> list[str]:
    categories = tokens["categories"]
    lines = [
        "// MARK: - Category colors",
        "",
        "/// Semantic itinerary-category colors (BUILD_PLAN.md §6.1). These are",
        "/// fixed brand assignments — flight is always sky, hotel always amber,",
        "/// activity always moss, food always plum. Do not reassign per trip.",
        "public enum CategoryColor {",
        "    public struct Pair {",
        "        public let fg: Color",
        "        public let soft: Color",
        "    }",
        "",
        "    public enum Key: String, CaseIterable {",
    ]
    for key in categories:
        lines.append(f"        case {key}")
    lines += ["    }", ""]

    for key, entry in categories.items():
        fg_hex = entry["fg"]["hex"]
        soft_light = entry["soft"]["light"]
        soft_dark = entry["soft"]["dark"]
        lines.append(f"    public static let {key} = Pair(")
        lines.append(f'        fg: dynamicColor(lightHex: "{fg_hex}", darkHex: "{fg_hex}"),')
        lines.append(f"        soft: {color_expr(soft_light, soft_dark)}")
        lines.append("    )")
        lines.append("")

    lines.append("    /// Looks up a category pair by key; unknown keys fall back to `flight`")
    lines.append("    /// rather than crashing (defensive against future/unknown category")
    lines.append("    /// strings arriving from the backend).")
    lines.append("    public static func pair(for key: Key) -> Pair {")
    lines.append("        switch key {")
    for key in categories:
        lines.append(f"        case .{key}: return {key}")
    lines.append("        }")
    lines.append("    }")
    lines += ["}", ""]
    return lines


def gen_gradients(tokens: dict) -> list[str]:
    gradients = tokens["gradients"]
    array_entries = {k: v for k, v in gradients.items() if isinstance(v, list)}
    alias_entries = {k: v for k, v in gradients.items() if isinstance(v, str)}

    lines = [
        "// MARK: - Cover gradients",
        "",
        "/// Trip cover gradients (BUILD_PLAN.md §6.1). Referenced by key from",
        "/// `Trip.cover_gradient` — never inline raw hex stops in a view.",
        "public enum CoverGradient {",
    ]
    for key, stops in array_entries.items():
        stop_exprs = ", ".join(f'Color(hex: "{stop}")' for stop in stops)
        lines.append(f"    public static let {swift_identifier(key)} = LinearGradient(")
        lines.append(f"        colors: [{stop_exprs}],")
        lines.append("        startPoint: .topLeading,")
        lines.append("        endPoint: .bottomTrailing")
        lines.append("    )")
        lines.append("")

    # Aliases (e.g. "default" -> "dusk") become a differently-named static
    # let, since `default` alone is a reserved Swift keyword.
    alias_names = {}
    for key, target in alias_entries.items():
        if target not in array_entries:
            sys.exit(f"gen_tokens: gradient alias '{key}' points at unknown key '{target}'")
        alias_name = f"{key}Gradient" if key in SWIFT_KEYWORDS else key
        alias_names[key] = alias_name
        lines.append(f"    /// Alias: \"{key}\" -> \"{target}\"")
        lines.append(f"    public static let {alias_name} = {target}")
        lines.append("")

    lines.append("    /// Resolves a `cover_gradient` token key to a gradient, falling back to")
    lines.append("    /// the default when the key is missing or not recognized. UX P6.5: anything")
    lines.append("    /// that doesn't match a curated key above is handed to")
    lines.append("    /// `CoverGradientGenerator.decode` (PaletteExtras.swift — hand-written,")
    lines.append("    /// never touched by this script) for the seeded-generator key format;")
    lines.append("    /// `nil` there (unknown/malformed) still falls back to the default here.")
    lines.append("    public static func from(key: String?) -> LinearGradient {")
    lines.append("        switch key?.lowercased() {")
    for key in array_entries:
        lines.append(f'        case "{key}": return {swift_identifier(key)}')
    for key, alias_name in alias_names.items():
        lines.append(f'        case "{key}": return {alias_name}')
    fallback = next(iter(alias_names.values()), next(iter(array_entries)))
    lines.append(f"        default: return CoverGradientGenerator.decode(key) ?? {fallback}")
    lines.append("        }")
    lines.append("    }")
    lines += ["}", ""]
    return lines


def gen_spacing(tokens: dict) -> list[str]:
    scale = tokens["spacing"]["scale"]
    names = tokens["spacing"]["names"]
    if len(scale) != len(names):
        sys.exit("gen_tokens: spacing.scale and spacing.names must be the same length")
    lines = [
        "// MARK: - Spacing",
        "",
        "/// Spacing scale (BUILD_PLAN.md §6). Use these instead of raw point",
        "/// values so the rhythm of the app stays consistent.",
        "public enum Spacing {",
    ]
    for name, value in zip(names, scale):
        lines.append(f"    public static let {swift_identifier(name)}: CGFloat = {fmt_number(value)}")
    lines.append(f"    /// The raw scale, smallest to largest: {scale}")
    lines.append(f"    public static let scale: [CGFloat] = [{', '.join(fmt_number(v) for v in scale)}]")
    lines += ["}", ""]
    return lines


def gen_radii(tokens: dict) -> list[str]:
    radii = tokens["radii"]
    lines = [
        "// MARK: - Radii",
        "",
        "public enum Radii {",
    ]
    for key, value in radii.items():
        lines.append(f"    public static let {swift_identifier(key)}: CGFloat = {fmt_number(value)}")
    lines += ["}", ""]
    return lines


def gen_typo(tokens: dict) -> list[str]:
    families = tokens["type"]["families"]
    sizes = tokens["type"]["sizes"]
    display_font = families["display"]["font"]
    body_font = families["body"]["font"]

    lines = [
        "// MARK: - Typography",
        "",
        "/// Type scale (BUILD_PLAN.md §6.2): Fraunces for display/titles, Sofia",
        "/// Sans for body/UI, monospace for confirmation codes. Fonts are bundled",
        "/// (Tripto/Resources/Fonts) and registered via UIAppFonts — see",
        "/// FontCheck for a DEBUG-time sanity check that they actually loaded.",
        "public enum Typo {",
        "    /// Named sizes from the type scale. Pass these to `display`/`body`,",
        "    /// or any custom size.",
        "    public enum Size {",
    ]
    for key, entry in sizes.items():
        lines.append(f"        public static let {swift_identifier(key)}: CGFloat = {fmt_number(entry['size'])}")
        if "lineHeight" in entry:
            lines.append(f"        public static let {key}LineHeight: CGFloat = {fmt_number(entry['lineHeight'])}")
    lines += ["    }", ""]

    lines.append(f'    private static let displayFamilyKeyword = "{display_font}"')
    lines.append(f'    private static let bodyFamilyKeyword = "{body_font}"')
    lines.append("")
    lines.append("    /// Display type — Fraunces. Used with restraint: city names and")
    lines.append("    /// screen titles (BUILD_PLAN.md §6.2). Weights available: "
                  + ", ".join(str(w) for w in families["display"]["weights"]) + ".")
    lines.append("    public static func display(_ size: CGFloat = Size.display, weight: Font.Weight = .semibold) -> Font {")
    lines.append("        Font(resolvedUIFont(familyKeyword: displayFamilyKeyword, size: size, weight: weight, textStyle: .title2))")
    lines.append("    }")
    lines.append("")
    lines.append("    /// Body/UI type — Sofia Sans. Weights available: "
                  + ", ".join(str(w) for w in families["body"]["weights"]) + ".")
    lines.append("    public static func body(_ size: CGFloat = Size.body, weight: Font.Weight = .regular) -> Font {")
    lines.append("        Font(resolvedUIFont(familyKeyword: bodyFamilyKeyword, size: size, weight: weight, textStyle: .body))")
    lines.append("    }")
    lines.append("")
    lines.append("    /// Data/confirmation-code type — system monospace (BUILD_PLAN.md §6.2).")
    lines.append("    public static func mono(_ size: CGFloat = Size.body) -> Font {")
    lines.append("        Font(resolvedMonoUIFont(size: size))")
    lines.append("    }")
    lines.append("")
    lines.append("    // MARK: - Dynamic Type-aware resolution (internal; exercised by tests)")
    lines.append("")
    lines.append("    /// Builds the weight-dialed custom `UIFont`, then scales it for the active")
    lines.append("    /// Dynamic Type setting via `UIFontMetrics(forTextStyle:)` so Fraunces and")
    lines.append("    /// Sofia grow with the user's accessibility text size the way the system")
    lines.append("    /// text styles do. `textStyle` picks the scaling curve (display uses a")
    lines.append("    /// title style, body uses `.body`). `traits` is injectable for tests.")
    lines.append("    static func resolvedUIFont(")
    lines.append("        familyKeyword: String, size: CGFloat, weight: Font.Weight,")
    lines.append("        textStyle: UIFont.TextStyle, compatibleWith traits: UITraitCollection? = nil")
    lines.append("    ) -> UIFont {")
    lines.append("        let base = variableBaseUIFont(familyKeyword: familyKeyword, size: size, weight: weight)")
    lines.append("        return UIFontMetrics(forTextStyle: textStyle).scaledFont(for: base, compatibleWith: traits)")
    lines.append("    }")
    lines.append("")
    lines.append("    /// Monospaced confirmation-code type, likewise Dynamic Type-aware.")
    lines.append("    static func resolvedMonoUIFont(")
    lines.append("        size: CGFloat, compatibleWith traits: UITraitCollection? = nil")
    lines.append("    ) -> UIFont {")
    lines.append("        let base = UIFont.monospacedSystemFont(ofSize: size, weight: .regular)")
    lines.append("        return UIFontMetrics(forTextStyle: .body).scaledFont(for: base, compatibleWith: traits)")
    lines.append("    }")
    lines += ["}", ""]
    return lines


def gen_variable_font_helper() -> list[str]:
    return [
        "// MARK: - Variable font plumbing",
        "",
        "/// Bundled Fraunces/Sofia Sans are variable TTFs. Plain `Font.custom` only",
        "/// ever resolves to a font's *default* instance, so dialing a specific",
        "/// weight needs the `wght` variation axis set directly on a",
        "/// `UIFontDescriptor` — the `.weight()` SwiftUI modifier does not",
        "/// reliably move a custom variable font's axis. See RESEARCH_FINDINGS.md",
        "/// item 4 / plan amendment #10.",
        "private enum VariableFontAxis {",
        "    /// Decimal form of the four-char axis tag 'wght'.",
        f"    static let weight = {WGHT_AXIS}",
        "}",
        "",
        "private func variableBaseUIFont(familyKeyword: String, size: CGFloat, weight: Font.Weight) -> UIFont {",
        "    guard",
        "        let family = UIFont.familyNames.first(where: { $0.localizedCaseInsensitiveContains(familyKeyword) }),",
        "        let postscriptName = UIFont.fontNames(forFamilyName: family).first",
        "    else {",
        "        // Font not registered (e.g. a plain SwiftUI preview or test target) —",
        "        // degrade to the system font rather than crashing. Still scaled for",
        "        // Dynamic Type by the caller.",
        "        return UIFont.systemFont(ofSize: size, weight: weight.uiKitWeight)",
        "    }",
        "    let variationAttribute = UIFontDescriptor.AttributeName(rawValue: kCTFontVariationAttribute as String)",
        "    let descriptor = UIFontDescriptor(name: postscriptName, size: size)",
        "        .addingAttributes([variationAttribute: [VariableFontAxis.weight: weight.variableAxisValue]])",
        "    return UIFont(descriptor: descriptor, size: size)",
        "}",
        "",
        "private extension Font.Weight {",
        "    /// Maps SwiftUI's semantic weight cases to a `wght` axis coordinate.",
        "    var variableAxisValue: CGFloat {",
        "        switch self {",
        "        case .ultraLight: return 100",
        "        case .thin: return 200",
        "        case .light: return 300",
        "        case .regular: return 400",
        "        case .medium: return 500",
        "        case .semibold: return 600",
        "        case .bold: return 700",
        "        case .heavy: return 800",
        "        case .black: return 900",
        "        default: return 400",
        "        }",
        "    }",
        "",
        "    /// The `UIFont.Weight` counterpart, used only for the system-font fallback",
        "    /// when the bundled variable face isn't registered.",
        "    var uiKitWeight: UIFont.Weight {",
        "        switch self {",
        "        case .ultraLight: return .ultraLight",
        "        case .thin: return .thin",
        "        case .light: return .light",
        "        case .regular: return .regular",
        "        case .medium: return .medium",
        "        case .semibold: return .semibold",
        "        case .bold: return .bold",
        "        case .heavy: return .heavy",
        "        case .black: return .black",
        "        default: return .regular",
        "        }",
        "    }",
        "}",
        "",
    ]


def main() -> None:
    tokens = json.loads(TOKENS_JSON.read_text())

    sections: list[str] = []
    sections += gen_header()
    sections += gen_dynamic_helpers()
    sections += gen_palette(tokens)
    sections += gen_category_colors(tokens)
    sections += gen_gradients(tokens)
    sections += gen_spacing(tokens)
    sections += gen_radii(tokens)
    sections += gen_typo(tokens)
    sections += gen_variable_font_helper()

    output = "\n".join(sections).rstrip("\n") + "\n"
    OUTPUT_SWIFT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_SWIFT.write_text(output)
    print(f"wrote {OUTPUT_SWIFT.relative_to(REPO_ROOT)} ({len(output.splitlines())} lines)")


if __name__ == "__main__":
    main()
