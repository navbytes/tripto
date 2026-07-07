import SwiftUI

/// A small rounded label used for statuses, countdowns, and category tags
/// (BUILD_PLAN.md §6.4 component list). Deliberately trivial — this is the
/// first view built against `Design/Tokens.swift`, proving the palette,
/// spacing, radii, and type tokens all wire up end to end.
struct PillLabel: View {
    enum Tint {
        case amber
        case category(CategoryColor.Key)
        case neutral
    }

    let text: String
    var tint: Tint = .amber

    var body: some View {
        Text(text)
            .font(Typo.body(Typo.Size.caption, weight: .semibold))
            .foregroundStyle(foreground)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .background(background, in: RoundedRectangle(cornerRadius: Radii.pill, style: .continuous))
    }

    private var foreground: Color {
        switch tint {
        case .amber: Palette.ink
        case .category(let key): CategoryColor.pair(for: key).fg
        case .neutral: Palette.slate
        }
    }

    private var background: Color {
        switch tint {
        case .amber: Palette.amberSoft
        case .category(let key): CategoryColor.pair(for: key).soft
        case .neutral: Palette.mist
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Spacing.sm) {
        PillLabel(text: "Design system online", tint: .amber)
        PillLabel(text: "Flight", tint: .category(.flight))
        PillLabel(text: "Hotel", tint: .category(.hotel))
        PillLabel(text: "Activity", tint: .category(.activity))
        PillLabel(text: "Food", tint: .category(.food))
        PillLabel(text: "Neutral", tint: .neutral)
    }
    .padding(Spacing.xl)
    .background(Palette.paper)
}
