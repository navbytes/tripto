import SwiftUI

/// Category → SF Symbol + `CategoryColor` pair, plus the two shapes the
/// timeline uses everywhere: the 38pt rounded icon tile on cards
/// (BUILD_PLAN.md §4.2/§6.4 `CategoryIcon`) and the small ring node on the
/// vertical rail. Color is never the only signal — the icon always rides
/// along (§7.3).
extension ItemCategory {
    var colorPair: CategoryColor.Pair {
        switch self {
        case .flight: CategoryColor.flight
        case .hotel: CategoryColor.hotel
        case .activity: CategoryColor.activity
        case .food: CategoryColor.food
        }
    }

    var symbolName: String {
        switch self {
        case .flight: "airplane"
        case .hotel: "bed.double.fill"
        case .activity: "camera.fill"
        case .food: "fork.knife"
        }
    }

    /// Form/selector label ("Stay", not the raw "hotel").
    var displayName: String {
        switch self {
        case .flight: "Flight"
        case .hotel: "Stay"
        case .activity: "Activity"
        case .food: "Food"
        }
    }
}

/// The 38pt icon tile on timeline cards and booking rows.
struct CategoryIconTile: View {
    let category: ItemCategory
    var side: CGFloat = 38

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.29, style: .continuous)
            .fill(category.colorPair.soft)
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: category.symbolName)
                    .font(.system(size: side * 0.47, weight: .medium))
                    .foregroundStyle(category.colorPair.fg)
            }
            .accessibilityLabel(category.displayName)
    }
}

/// The small category-colored ring on the timeline's vertical rail.
struct RailNode: View {
    let category: ItemCategory
    var diameter: CGFloat = 12

    var body: some View {
        Circle()
            .fill(Palette.elevated)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle().stroke(category.colorPair.fg, lineWidth: 2.5)
            }
    }
}

#Preview {
    HStack(spacing: Spacing.lg) {
        VStack(spacing: Spacing.md) {
            ForEach(ItemCategory.allCases, id: \.self) { CategoryIconTile(category: $0) }
        }
        VStack(spacing: Spacing.md) {
            ForEach(ItemCategory.allCases, id: \.self) { RailNode(category: $0) }
        }
    }
    .padding(Spacing.xl)
    .background(Palette.paper)
}

/// `PackingGroupKey` → section title + SF Symbol, the packing-list
/// equivalent of `ItemCategory`'s mapping above (BUILD_PLAN.md §3.3;
/// docs/TripAppFamily.jsx's `Packing` mockup groups: Documents/Kids/Shared —
/// extended here to all 5 server-side `group_key` values).
extension PackingGroupKey {
    var displayName: String {
        switch self {
        case .documents: "Documents"
        case .kids: "Kids"
        case .shared: "Shared"
        case .clothing: "Clothing"
        case .custom: "Other"
        }
    }

    var symbolName: String {
        switch self {
        case .documents: "doc.text.fill"
        case .kids: "figure.and.child.holdinghands"
        case .shared: "bolt.fill"
        case .clothing: "tshirt.fill"
        case .custom: "ellipsis.circle.fill"
        }
    }
}
