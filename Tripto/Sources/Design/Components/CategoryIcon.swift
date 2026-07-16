import SwiftUI

/// Category → SF Symbol + `CategoryColor` pair, plus the two shapes the
/// timeline uses everywhere: the 38pt rounded icon tile on cards
/// (BUILD_PLAN.md §4.2/§6.4 `CategoryIcon`) and the small ring node on the
/// vertical rail. Color is never the only signal — the icon always rides
/// along (§7.3).
extension ItemCategory {
    /// The `Platform/Shared` join key for this category (DRY M1 #3): same
    /// 5 cases, same raw values (`SnapshotItem.Category`'s own doc
    /// comment) — the icon/label/color mapping below lives once, on the
    /// shared type (`Platform/Shared/CategoryPresentation.swift`), keyed
    /// through this bridge rather than duplicated here.
    private var snapshotCategory: SnapshotItem.Category {
        switch self {
        case .flight: .flight
        case .hotel: .hotel
        case .activity: .activity
        case .food: .food
        case .transport: .transport
        }
    }

    var colorPair: CategoryColor.Pair { snapshotCategory.colorPair }
    var symbolName: String { snapshotCategory.symbolName }

    /// Form/selector label ("Stay", not the raw "hotel").
    var displayName: String { snapshotCategory.displayName }
}

/// The 38pt icon tile on timeline cards and booking rows.
struct CategoryIconTile: View {
    let category: ItemCategory
    /// D4 ("now" presence): past-row de-elevation — a neutral slate fill/
    /// glyph instead of the category's own accent, so a past card reads as
    /// "receded" without touching any text color (AA stays untouched by
    /// construction). Defaults `false` so every other call site (bookings
    /// list, booking detail, suggested-items sheet) renders exactly as
    /// before.
    var dimmed: Bool = false
    /// UX-audit residue (T1 report): `side` used to be a plain stored
    /// `CGFloat`, so every Features/Trip call site's tile — and its
    /// `side * 0.47` glyph — stayed pinned at its base point size while the
    /// row's own adjacent text scaled around it with Dynamic Type.
    /// `@ScaledMetric` grows the whole tile (container + glyph together,
    /// same recipe as `PackingListView`'s checkbox) on the shared `.body`
    /// curve; at the default content size category it returns exactly the
    /// base value passed in, so default-size rendering everywhere this is
    /// used (Home's `TripCard` doesn't use this component; only
    /// Features/Trip does) is unchanged.
    @ScaledMetric private var side: CGFloat

    init(category: ItemCategory, side: CGFloat = 38, dimmed: Bool = false) {
        self.category = category
        self.dimmed = dimmed
        self._side = ScaledMetric(wrappedValue: side, relativeTo: .body)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: side * 0.29, style: .continuous)
            .fill(dimmed ? Palette.mist : category.colorPair.soft)
            .frame(width: side, height: side)
            .overlay {
                Image(systemName: category.symbolName)
                    .font(.system(size: side * 0.47, weight: .medium))
                    .foregroundStyle(dimmed ? Palette.slate : category.colorPair.fg)
            }
            .accessibilityLabel(category.displayName)
    }
}

/// The small category-colored ring on the timeline's vertical rail.
struct RailNode: View {
    let category: ItemCategory
    var diameter: CGFloat = 12
    /// D4: see `CategoryIconTile.dimmed`'s doc comment — same past-row
    /// treatment, same default-`false`/unchanged-elsewhere guarantee.
    var dimmed: Bool = false

    var body: some View {
        Circle()
            .fill(Palette.elevated)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle().stroke(dimmed ? Palette.slate : category.colorPair.fg, lineWidth: 2.5)
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
