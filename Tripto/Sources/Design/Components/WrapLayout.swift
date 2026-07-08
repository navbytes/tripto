import SwiftUI

/// UX audit finding 2: `TimelineCardRow`'s assignees+tags row used to be a
/// plain `HStack`, so a card with an `AvatarStack` plus two or three tag
/// chips (BUILD_PLAN.md §5.4's kid-aware tags — a headline family signal,
/// not a footnote) ran out of width and ellipsized instead of wrapping, at
/// default type size with as few as three chips, worse at accessibility
/// sizes. A leading-aligned flow layout that wraps to a new row instead of
/// clipping. Deliberately dumb: leading alignment only, no RTL
/// special-casing (`Layout`'s placement coordinates are already flipped by
/// SwiftUI for RTL locales when placed via `bounds.minX`-relative math, as
/// this is), no animation logic — callers that want an animated wrap should
/// wrap this in `.animation(_:value:)` themselves.
struct WrapLayout: Layout {
    var horizontalSpacing: CGFloat = Spacing.xs
    var verticalSpacing: CGFloat = Spacing.xs

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.replacingUnspecifiedDimensions().width
        let rows = arrangeRows(subviews: subviews, maxWidth: maxWidth)
        let height = rows.reduce(CGFloat(0)) { partial, row in
            partial + row.height + (partial > 0 ? verticalSpacing : 0)
        }
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let rows = arrangeRows(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for item in row.items {
                let yOffset = (row.height - item.size.height) / 2
                item.subview.place(
                    at: CGPoint(x: x, y: y + yOffset),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    // MARK: - Row math

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        let items: [Item]
        let width: CGFloat
        let height: CGFloat
    }

    /// Packs subviews into rows against `maxWidth`. `maxWidth` of `.infinity`
    /// (an unspecified-width probe — SwiftUI proposes this before the parent
    /// has settled a width, e.g. inside a `ScrollView`) falls back to a
    /// single row of every subview at its ideal size, since there's no
    /// meaningful width to wrap against yet.
    private func arrangeRows(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        guard !subviews.isEmpty else { return [] }
        guard maxWidth.isFinite else {
            let items = subviews.map { Item(subview: $0, size: $0.sizeThatFits(.unspecified)) }
            let width = items.reduce(CGFloat(0)) { $0 + $1.size.width } + horizontalSpacing * CGFloat(max(0, items.count - 1))
            let height = items.map(\.size.height).max() ?? 0
            return [Row(items: items, width: width, height: height)]
        }

        var rows: [Row] = []
        var currentItems: [Item] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let neededWidth = currentWidth == 0 ? size.width : currentWidth + horizontalSpacing + size.width
            if !currentItems.isEmpty && neededWidth > maxWidth {
                rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = [Item(subview: subview, size: size)]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentItems.append(Item(subview: subview, size: size))
                currentWidth = neededWidth
                currentHeight = max(currentHeight, size.height)
            }
        }
        if !currentItems.isEmpty {
            rows.append(Row(items: currentItems, width: currentWidth, height: currentHeight))
        }
        return rows
    }
}

/// Validate-first artifact (implementation plan step 1): pins `sizeThatFits`
/// under both a constrained width (chips must wrap) and an unspecified width
/// (must fall back to a single row, not crash/collapse) before this is wired
/// into `TimelineCardRow`.
#Preview("WrapLayout") {
    VStack(alignment: .leading, spacing: Spacing.lg) {
        Text("Constrained width (wraps)")
            .font(Typo.body(11, weight: .bold))
            .foregroundStyle(Palette.slate)
        WrapLayout(horizontalSpacing: Spacing.xs, verticalSpacing: Spacing.xs) {
            AvatarStack(
                people: [
                    .init(id: UUID(), initial: "N", colorName: "amber"),
                    .init(id: UUID(), initial: "P", colorName: "moss"),
                ],
                maxVisible: 4,
                diameter: 18
            )
            TagChip(tag: "nap")
            TagChip(tag: "stroller-ok")
            TagChip(tag: "kids-menu")
        }
        .frame(width: 160, alignment: .leading)
        .background(Palette.mist.opacity(0.3))

        Text("Unspecified width (single row)")
            .font(Typo.body(11, weight: .bold))
            .foregroundStyle(Palette.slate)
        ScrollView(.horizontal) {
            WrapLayout(horizontalSpacing: Spacing.xs, verticalSpacing: Spacing.xs) {
                TagChip(tag: "nap")
                TagChip(tag: "stroller-ok")
                TagChip(tag: "kids-menu")
            }
        }
        .background(Palette.mist.opacity(0.3))
    }
    .padding(Spacing.lg)
    .background(Palette.paper)
}
