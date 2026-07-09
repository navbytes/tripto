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
    static let railWidth: CGFloat = 14

    /// Finding F5: a fixed 44pt time gutter clips at accessibility Dynamic
    /// Type sizes ("08:20" + a zone label no longer fit). `CheckOutRow`
    /// shares this (rather than its own private width) so the two row
    /// kinds' columns stay aligned regardless of type size.
    ///
    /// Finding F1: the old two-step (44pt / 76pt) jump left every size
    /// between "default" and "accessibility" either clipped or wasting
    /// space. This now steps with `Typo`'s own `UIFontMetrics(.body)` curve
    /// — one width bump per Dynamic Type step up to `.xxxLarge`, then the
    /// same 76pt AX ceiling as before once accessibility sizes kick in.
    /// Takes the full `DynamicTypeSize` (not a plain `Bool`) so it can key
    /// off more than just the AX/non-AX split; call sites already carry
    /// this value as `typeSize` for the `.equatable()` short-circuit fix
    /// (see `TimelineCardRow`'s doc comment).
    static func gutterWidth(for size: DynamicTypeSize) -> CGFloat {
        if size.isAccessibilitySize { return 76 }
        switch size {
        case .xSmall, .small, .medium, .large: return 44
        case .xLarge: return 50
        case .xxLarge: return 56
        case .xxxLarge: return 62
        default: return 44
        }
    }

    /// Left indent for rows with no gutter/rail of their own (staying
    /// strips, tz-shift chips) so they still line up under the card column.
    static func indentedLeading(for size: DynamicTypeSize) -> CGFloat {
        gutterWidth(for: size) + railWidth + Spacing.sm
    }
}

struct TimelineCardRow: View, Equatable {
    let model: TimelineCardModel
    /// Finding F5: `dynamicTypeSize`, read by the caller and passed in as a
    /// stored property (rather than read here via `@Environment`) so it
    /// participates in the `==` below — `.equatable()` views can otherwise
    /// miss a live Dynamic Type change entirely, since the equality check is
    /// what decides whether SwiftUI re-evaluates `body` at all. Finding F1:
    /// carries the full `DynamicTypeSize` (not just an AX/non-AX `Bool`) so
    /// `TimelineLayout.gutterWidth` can step the gutter width with it;
    /// `isAXSize` below stays a derived computed var so the existing
    /// `lineLimit(isAXSize ? 2 : 1)` call sites are untouched.
    var typeSize: DynamicTypeSize = .large

    private var isAXSize: Bool { typeSize.isAccessibilitySize }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model && lhs.typeSize == rhs.typeSize }

    var body: some View {
        NavigationLink(value: ItemRoute(id: model.id)) {
            HStack(alignment: .top, spacing: 0) {
                timeGutter
                railColumn
                card
            }
            // One spoken element per row: names the category (conveyed only
            // by node color + icon tile visually — never color alone, §7.3),
            // then title/subtitle/time and status. The NavigationLink supplies
            // the button trait.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
        }
        .buttonStyle(.plain)
        .padding(.vertical, Spacing.xs)
    }

    private var categoryWord: String { model.category.displayName }

    private var a11yLabel: String {
        var parts = [categoryWord, model.title]
        // UX audit finding 5: several categories' subtitle falls back to
        // their bare category word ("Flight"/"Activity"/"Food"/"Transport"
        // — `TimelineBuilder.subtitle`'s empty-details fallback), which
        // VoiceOver then read twice back to back. Skipping the subtitle
        // when it's just a repeat of `categoryWord` leaves the visual card
        // (which still wants a non-empty second line) untouched.
        if model.subtitle != categoryWord {
            parts.append(model.subtitle)
        }
        parts.append("at \(model.timeText)\(model.zoneLabel.map { " \($0)" } ?? "")")
        if !model.assignees.isEmpty {
            parts.append(Self.assigneesPhrase(for: model.assignees))
        }
        for tag in model.tags { parts.append(ItemTag(rawValue: tag)?.label ?? tag) }
        if model.hasTicket { parts.append("has a confirmation") }
        if model.isPending { parts.append("waiting to sync") }
        if let editedBy = model.editedBy { parts.append(editedBy) }
        return parts.joined(separator: ", ")
    }

    /// Finding F4: names beat a bare count when they're available — "for
    /// Meera" reads better than "for 1 person". Falls back to the old
    /// "for N people" wording whenever any assignee's `name` is empty (older
    /// call sites that haven't threaded a name through yet), so this never
    /// silently drops someone's presence from the count. Internal (not
    /// `private`) so a unit test can pin the pluralization/overflow wording
    /// directly.
    static func assigneesPhrase(for assignees: [AvatarStack.Person]) -> String {
        let names = assignees.map(\.name).filter { !$0.isEmpty }
        guard names.count == assignees.count, !names.isEmpty else {
            return "for \(assignees.count) \(assignees.count == 1 ? "person" : "people")"
        }
        switch names.count {
        case 1: return "for \(names[0])"
        case 2: return "for \(names[0]) and \(names[1])"
        case 3: return "for \(names[0]), \(names[1]), and \(names[2])"
        default:
            let others = names.count - 2
            return "for \(names[0]), \(names[1]), and \(others) other\(others == 1 ? "" : "s")"
        }
    }

    private var timeGutter: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(model.timeText)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.ink)
                .lineLimit(1)
            if let zoneLabel = model.zoneLabel {
                Text(zoneLabel)
                    .font(Typo.body(9.5, weight: .medium))
                    .foregroundStyle(Palette.slate)
                    // UX audit finding 3: this zone label is
                    // safety-critical (it's a flight/transit's
                    // departure/arrival time zone), so it must stay legible
                    // rather than shrink toward illegibility at
                    // accessibility sizes. `isAXSize` already widens the
                    // gutter to 76pt (`TimelineLayout.gutterWidth`), which
                    // gives a second line room to wrap into instead of
                    // scaling the text down further.
                    .lineLimit(isAXSize ? 2 : 1)
                    .minimumScaleFactor(isAXSize ? 0.85 : 0.8)
                    .allowsTightening(true)
            }
        }
        .frame(width: TimelineLayout.gutterWidth(for: typeSize), alignment: .trailing)
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
                    .lineLimit(isAXSize ? 2 : 1)
                Text(model.subtitle)
                    .font(Typo.body(Typo.Size.caption))
                    .foregroundStyle(Palette.slate)
                    .lineLimit(isAXSize ? 2 : 1)
                if !model.assignees.isEmpty || !model.tags.isEmpty {
                    // Finding 2: a plain `HStack` here ellipsized instead of
                    // wrapping once avatars + a couple of kid-aware tags
                    // (§5.4) outran the card's width — `WrapLayout` flows
                    // extra chips onto a new line instead.
                    WrapLayout(horizontalSpacing: Spacing.xs, verticalSpacing: Spacing.xs) {
                        if !model.assignees.isEmpty {
                            AvatarStack(people: model.assignees, maxVisible: 4, diameter: 18)
                        }
                        ForEach(model.tags, id: \.self) { tag in
                            TagChip(tag: tag)
                        }
                    }
                    .padding(.top, 1)
                }
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
        .shadow(color: Palette.shadow.opacity(0.08), radius: 6, y: 3)
        .padding(.leading, Spacing.sm)
    }
}

/// Quiet mid-stay marker (ACCEPTANCE.md "(c)") — deliberately no time
/// gutter/rail node of its own; it indents to sit under the card column so
/// it reads as a backdrop, not a competing event. Finding F3: now tappable
/// (same `ItemRoute` the check-in card and check-out chip already use) so a
/// traveler mid-scroll on a "staying" day can still reach the hotel's
/// details without hunting for the check-in card above it.
struct StayingStripRow: View, Equatable {
    let model: StayingStripModel
    /// See `TimelineCardRow.typeSize`'s doc comment — same
    /// `.equatable()`-vs-Dynamic-Type fix, needed here too so the indent
    /// stays aligned with the card/check-out columns at every type size.
    var typeSize: DynamicTypeSize = .large

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model && lhs.typeSize == rhs.typeSize }

    var body: some View {
        NavigationLink(value: ItemRoute(id: model.itemId)) {
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
            // Finding F5's 44pt hit-target rule now applies here too, since
            // this strip is interactive — a visual capsule centered in a
            // 44pt band, the same pattern `PersonFilterBar`'s chips use.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // Finding F9: one spoken stop for the strip, not two (an icon +
            // text pair VoiceOver would otherwise announce separately).
            // Inside the link label — not appended after `.buttonStyle`
            // below — so the NavigationLink itself supplies the button
            // trait and activation, matching `TimelineCardRow`.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.text)
        }
        .buttonStyle(.plain)
        .padding(.leading, TimelineLayout.indentedLeading(for: typeSize))
        .padding(.vertical, Spacing.xxs)
    }
}

/// Compact check-out marker — deliberately smaller and rail-node-free so it
/// never reads as a second full booking (ACCEPTANCE.md "(c)"). Shares
/// `TimelineLayout.gutterWidth` with `TimelineCardRow` (finding F5) so its
/// own time column lines up with every card's, with no private width or
/// hand-tuned offset needed to make that true.
struct CheckOutRow: View, Equatable {
    let model: CheckOutRowModel
    /// See `TimelineCardRow.typeSize`'s doc comment.
    var typeSize: DynamicTypeSize = .large

    private var isAXSize: Bool { typeSize.isAccessibilitySize }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model && lhs.typeSize == rhs.typeSize }

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
                    .lineLimit(isAXSize ? 2 : 1)
                if model.isPending { PendingSyncChip() }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(Palette.mist.opacity(0.5), in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
            // Finding F4: the capsule visually reads shorter than 44pt —
            // same "visual capsule centered in a 44pt hit band" pattern as
            // `PersonFilterBar`'s chips (Finding 1b), visuals unchanged.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            // Finding F9: one spoken stop — "Check-out · title, at time zone,
            // waiting to sync" — instead of the gutter/icon/title/pending
            // chip reading as separate VoiceOver stops. Inside the link
            // label so the NavigationLink itself supplies the button trait
            // and activation, matching `TimelineCardRow`.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(a11yLabel)
        }
        .buttonStyle(.plain)
        .padding(.vertical, Spacing.xxs)
    }

    private var a11yLabel: String {
        var parts = [model.title, "at \(model.timeText)\(model.zoneLabel.map { " \($0)" } ?? "")"]
        if model.isPending { parts.append("waiting to sync") }
        return parts.joined(separator: ", ")
    }

    private var timeGutter: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(model.timeText)
                .font(Typo.body(11, weight: .semibold))
                .foregroundStyle(Palette.slate)
                .lineLimit(1)
            if let zoneLabel = model.zoneLabel {
                Text(zoneLabel)
                    .font(Typo.body(9, weight: .medium))
                    .foregroundStyle(Palette.slate)
                    // UX audit finding 3: see `TimelineCardRow.timeGutter`'s
                    // matching comment — same safety-critical
                    // wrap-not-shrink treatment for the check-out row's own
                    // zone label.
                    .lineLimit(isAXSize ? 2 : 1)
                    .minimumScaleFactor(isAXSize ? 0.85 : 0.8)
                    .allowsTightening(true)
            }
        }
        .frame(width: TimelineLayout.gutterWidth(for: typeSize), alignment: .trailing)
    }
}

/// Kid-aware tag chip (BUILD_PLAN.md §5.4, this milestone's brief:
/// "rendered as small moss chips" — the moss now lives in the background
/// tint; see Finding 6 below for the label/icon color). `tag` is the raw
/// `details.tags` string; unrecognized values (a future tag this build
/// doesn't know) still render, just as plain text with no icon, rather than
/// being dropped.
struct TagChip: View {
    let tag: String

    /// Finding 2: a chip wider than the whole content column (e.g.
    /// "Stroller-friendly" beside a 76pt AX gutter) used to ellipsize its
    /// label at accessibility sizes — same `lineLimit(isAXSize ? 2 : 1)`
    /// convention as the card's title/subtitle. Read via `@Environment`
    /// (rather than threaded in) since this view isn't itself `.equatable()`
    /// — its parent (`TimelineCardRow`) already carries `typeSize` in its
    /// own `==`, so a live type-size change still re-triggers this body.
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var itemTag: ItemTag? { ItemTag(rawValue: tag) }

    var body: some View {
        HStack(spacing: 3) {
            if let symbolName = itemTag?.symbolName {
                Image(systemName: symbolName).font(.system(size: 9, weight: .semibold))
            }
            Text(itemTag?.label ?? tag)
        }
        .font(Typo.body(10, weight: .bold))
        // Finding 6: `CategoryColor.activity.fg` (moss-on-moss-soft) was
        // under AA contrast at this chip's 10pt size — `Palette.ink` is the
        // same ink-on-soft-tint pairing `TZShiftChipRow`/`PersonFilterBanner`
        // already use, and it adapts light/dark like every other label.
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, 3)
        .background(CategoryColor.activity.soft, in: Capsule())
        .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
    }
}

/// The rail's tz-shift pill (ACCEPTANCE.md "(a)" point 3) — indents to the
/// same column as the staying strip so it reads as part of the rail, not a
/// card.
struct TZShiftChipRow: View, Equatable {
    let model: TZShiftModel
    /// See `TimelineCardRow.typeSize`'s doc comment.
    var typeSize: DynamicTypeSize = .large

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.model == rhs.model && lhs.typeSize == rhs.typeSize }

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
        .padding(.leading, TimelineLayout.indentedLeading(for: typeSize))
        .padding(.vertical, Spacing.xxs)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Finding F9: the arrow glyph is decorative — without this, it's a
        // second VoiceOver stop with nothing to say.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.text)
    }
}

/// Finding F1's validate-first artifact: the width table above pinned at
/// `.xxLarge` with a half-hour-zone flight (Asia/Kolkata's "GMT+5:30" — the
/// widest routine case, ACCEPTANCE.md's own half-hour-zone callout) and a
/// card whose zone label takes `ItineraryTimeZone.zoneLabel`'s
/// nil-abbreviation fallback (`citySegment(of:)`, a bare city name rather
/// than a short abbreviation). Both must render their zone label on one
/// line inside the stepped gutter at this size.
#Preview("Gutter at xxLarge") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TimelineCardRow(
                model: TimelineCardModel(
                    id: UUID(), category: .flight, timeText: "08:20", zoneLabel: "GMT+5:30",
                    title: "Flight to Delhi", subtitle: "JFK → DEL · Seat 14C", hasTicket: true,
                    isPending: false, editedBy: nil, assignees: [], tags: []
                ),
                typeSize: .xxLarge
            )
            .equatable()
            TimelineCardRow(
                model: TimelineCardModel(
                    id: UUID(), category: .activity, timeText: "14:00", zoneLabel: "Kathmandu",
                    title: "Boudhanath walking tour", subtitle: "Kathmandu", hasTicket: false,
                    isPending: false, editedBy: nil, assignees: [], tags: []
                ),
                typeSize: .xxLarge
            )
            .equatable()
            // Finding 2's validate-first artifact: avatars + three kid-aware
            // tags (§5.4) at the 56pt `.xxLarge` gutter — the exact
            // avatars-plus-tags-overrun-the-width state the finding says was
            // never pinned. Must wrap onto new lines, not ellipsize.
            TimelineCardRow(
                model: TimelineCardModel(
                    id: UUID(), category: .food, timeText: "12:30", zoneLabel: nil,
                    title: "Lunch at Thamel House", subtitle: "Kathmandu", hasTicket: false,
                    isPending: false, editedBy: nil,
                    assignees: [
                        .init(id: UUID(), initial: "N", colorName: "amber", name: "Naveen"),
                        .init(id: UUID(), initial: "P", colorName: "moss", name: "Priya"),
                        .init(id: UUID(), initial: "K", colorName: "plum", name: "Kiran"),
                    ],
                    tags: ["nap", "stroller-ok", "kids-menu"]
                ),
                typeSize: .xxLarge
            )
            .equatable()
        }
        .padding(Spacing.lg)
    }
    .dynamicTypeSize(.xxLarge)
    .background(Palette.paper)
}

/// UX audit finding 3's validate-first artifact: the same half-hour-zone
/// flight, at an accessibility Dynamic Type size where the 76pt AX gutter
/// (`TimelineLayout.gutterWidth`) kicks in. The zone label must wrap onto a
/// second line rather than shrink below its base size — confirms the
/// `lineLimit(isAXSize ? 2 : 1)` / `minimumScaleFactor(isAXSize ? 0.85 : 0.8)`
/// pairing above actually gives it room to do that.
#Preview("Gutter at accessibility2") {
    ScrollView {
        VStack(alignment: .leading, spacing: Spacing.md) {
            TimelineCardRow(
                model: TimelineCardModel(
                    id: UUID(), category: .flight, timeText: "08:20", zoneLabel: "GMT+5:30",
                    title: "Flight to Delhi", subtitle: "JFK → DEL · Seat 14C", hasTicket: true,
                    isPending: false, editedBy: nil, assignees: [], tags: []
                ),
                typeSize: .accessibility2
            )
            .equatable()
        }
        .padding(Spacing.lg)
    }
    .dynamicTypeSize(.accessibility2)
    .background(Palette.paper)
}
