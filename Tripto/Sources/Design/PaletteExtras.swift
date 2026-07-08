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
}
