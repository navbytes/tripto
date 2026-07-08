import SwiftUI

/// Row views for `ItineraryTabView`, one per `TimelineRowModel` case. Every
/// row is `View & Equatable` over its own value-snapshot model (§7.2:
/// "Equatable row views over value snapshots so unrelated pendingRowIds
/// changes don't re-render every card") — call sites apply `.equatable()`
/// so SwiftUI skips re-evaluating a row's body when its model didn't
/// change, even though the parent's `[TimelineDayModel]` array is rebuilt
/// on every render pass.
///
/// Layout constants (44pt gutter, 14pt rail column) are shared here so the
/// gutter/rail/card alignment matches across card rows and the strips/chips
/// that indent underneath them.
enum TimelineLayout {
    static let gutterWidth: CGFloat = 44
    static let railWidth: CGFloat = 14
    /// Left indent for rows with no gutter/rail of their own (staying
    /// strips, tz-shift chips) so they still line up under the card column.
    static let indentedLeading: CGFloat = gutterWidth + railWidth + Spacing.sm
}

struct TimelineCardRow: View, Equatable {
    let model: TimelineCardModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model }

    var body: some View {
        NavigationLink(value: ItemRoute(id: model.id)) {
            HStack(alignment: .top, spacing: 0) {
                timeGutter
                railColumn
                card
            }
        }
        .buttonStyle(.plain)
        .padding(.vertical, Spacing.xs)
    }

    private var timeGutter: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(model.timeText)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.ink)
            if let zoneLabel = model.zoneLabel {
                Text(zoneLabel)
                    .font(Typo.body(9.5, weight: .medium))
                    .foregroundStyle(Palette.slate)
            }
        }
        .frame(width: TimelineLayout.gutterWidth, alignment: .trailing)
        .padding(.top, 13)
        .padding(.trailing, Spacing.sm)
    }

    private var railColumn: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(Palette.mist)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
            RailNode(category: model.category)
                .padding(.top, 15)
        }
        .frame(width: TimelineLayout.railWidth)
    }

    private var card: some View {
        HStack(spacing: Spacing.md) {
            CategoryIconTile(category: model.category)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(Typo.body(Typo.Size.body, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                Text(model.subtitle)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                    .lineLimit(1)
                if model.isPending || model.editedBy != nil {
                    HStack(spacing: Spacing.xs) {
                        if model.isPending { PendingSyncChip() }
                        if let editedBy = model.editedBy {
                            Text(editedBy)
                                .font(Typo.body(10, weight: .medium))
                                .foregroundStyle(Palette.slate)
                                .lineLimit(1)
                        }
                    }
                }
            }
            Spacer(minLength: Spacing.xs)
            if model.hasTicket {
                Image(systemName: "ticket.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(Palette.slate)
            }
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm + 2)
        .background(Palette.elevated, in: RoundedRectangle(cornerRadius: Radii.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radii.card, style: .continuous)
                .strokeBorder(
                    model.isPending ? Palette.slate.opacity(0.35) : Color.clear,
                    style: StrokeStyle(lineWidth: 1.25, dash: model.isPending ? [5, 4] : [])
                )
        }
        .shadow(color: Palette.ink.opacity(0.08), radius: 6, y: 3)
        .padding(.leading, Spacing.sm)
    }
}

/// Quiet mid-stay marker (ACCEPTANCE.md "(c)") — deliberately no time
/// gutter/rail node of its own; it indents to sit under the card column so
/// it reads as a backdrop, not a competing event.
struct StayingStripRow: View, Equatable {
    let model: StayingStripModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "bed.double.fill")
                .font(.system(size: 12))
                .foregroundStyle(CategoryColor.hotel.fg)
            Text(model.text)
                .font(Typo.body(Typo.Size.caption, weight: .medium))
                .foregroundStyle(Palette.ink.opacity(0.85))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Palette.amberSoft.opacity(0.6), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        .padding(.leading, TimelineLayout.indentedLeading)
        .padding(.vertical, Spacing.xxs)
    }
}

/// Compact check-out marker — deliberately smaller and rail-node-free so it
/// never reads as a second full booking (ACCEPTANCE.md "(c)").
struct CheckOutRow: View, Equatable {
    let model: CheckOutRowModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model }

    var body: some View {
        NavigationLink(value: ItemRoute(id: model.itemId)) {
            HStack(spacing: Spacing.sm) {
                timeGutter
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12))
                    .foregroundStyle(CategoryColor.hotel.fg)
                Text(model.title)
                    .font(Typo.body(Typo.Size.caption, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                if model.isPending { PendingSyncChip() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Palette.mist.opacity(0.5), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.leading, TimelineLayout.gutterWidth + TimelineLayout.railWidth - 40)
        .padding(.vertical, Spacing.xxs)
    }

    private var timeGutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(model.timeText)
                .font(Typo.body(11, weight: .semibold))
                .foregroundStyle(Palette.slate)
            if let zoneLabel = model.zoneLabel {
                Text(zoneLabel)
                    .font(Typo.body(9, weight: .medium))
                    .foregroundStyle(Palette.slate)
            }
        }
        .frame(width: 40, alignment: .trailing)
    }
}

/// The rail's tz-shift pill (ACCEPTANCE.md "(a)" point 3) — indents to the
/// same column as the staying strip so it reads as part of the rail, not a
/// card.
struct TZShiftChipRow: View, Equatable {
    let model: TZShiftModel

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "arrow.left.arrow.right")
                .font(.system(size: 10, weight: .semibold))
            Text(model.text)
                .font(Typo.body(11, weight: .semibold))
        }
        // `.ink` (not `.indigo`, which is a fixed dark navy in both color
        // schemes and nearly unreadable against this chip's dark-mode
        // background) — `.ink` adapts light/dark like every other label.
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.xs)
        .background(Palette.amberSoft, in: Capsule())
        .padding(.leading, TimelineLayout.indentedLeading)
        .padding(.vertical, Spacing.xxs)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
