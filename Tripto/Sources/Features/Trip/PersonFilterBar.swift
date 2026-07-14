import SwiftUI

/// The "Just mine" person filter atop the itinerary (BUILD_PLAN.md §5.4;
/// docs/UX_REDESIGN_ROADMAP.md Phase 2 (P2.3) / design/ux-redesign-2026-07/
/// tripto-redesign.html is the current visual reference): "Everyone" + one
/// chip per `TripProfile`, horizontal scroll, no standing label — the row
/// of avatar chips already says what it's for. `TripView` owns the actual
/// filtering (`PersonFilter.filteredItems`) and the selection state (`nil`
/// = Everyone) — this is a pure renderer.
struct PersonFilterBar: View {
    struct Chip: Identifiable {
        let id: UUID
        let firstName: String
        let initial: String
        let colorName: String
    }

    let chips: [Chip]
    @Binding var selection: UUID?

    /// Finding 1: widths of the chip row / its scroll viewport, read via
    /// `.onGeometryChange` so the trailing overflow scrim below only shows
    /// when there's actually more to scroll to — not as a standing
    /// decoration on a bar that already fits everything.
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    /// See the shared `@ScaledMetric` recipe used throughout Features/Trip
    /// — sits next to the "Everyone" chip's own scaling label text.
    @ScaledMetric(relativeTo: .body) private var everyoneIconSize: CGFloat = 12

    private var hasOverflow: Bool {
        contentWidth > containerWidth - 2 * Spacing.xl + 1
    }

    var body: some View {
        // P2.3: the old standing "Showing plans for" label is gone — the
        // chip row is the whole bar now, one 56pt-tall row instead of a
        // label row plus a separate chip row. `minHeight` (not a fixed
        // `height`): at accessibility Dynamic Type sizes a chip's own
        // content can outgrow 56pt (its label text scales too), and this
        // must never clip that — it only floors the row at 56pt when
        // content is shorter, same "floor, not ceiling" reasoning as every
        // `minHeight: 44` hit-target below.
        //
        // Finding 1: horizontal padding used to live inside the ScrollView
        // (on the chip HStack), so a mid-scroll chip clipped ~22pt short of
        // the true screen edge — a paper-colored gutter sighted users could
        // easily mistake for "that's the end of the list." Padding now
        // lives outside as `.contentMargins`, so the ScrollView itself
        // spans the full width and chips clip flush with the edge while
        // scrolling, only inset at rest.
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                everyoneChip
                ForEach(chips) { chip in
                    personChip(chip)
                }
            }
            .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { contentWidth = $0 }
        }
        .frame(minHeight: 56)
        .contentMargins(.horizontal, Spacing.xl, for: .scrollContent)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { containerWidth = $0 }
        .overlay(alignment: .trailing) {
            // Sighted-only overflow cue (VoiceOver already reaches every
            // chip by swiping) — same paper-to-clear scrim pattern as
            // `ItineraryTabView.dayHeaderBackground`, using `Palette
            // .paper` since that's this bar's own background below.
            if hasOverflow {
                LinearGradient(
                    colors: [Palette.paper.opacity(0), Palette.paper],
                    startPoint: .leading, endPoint: .trailing
                )
                .frame(width: Spacing.xl)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
        }
        .background(Palette.paper)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Palette.mist).frame(height: 1)
        }
    }

    private var everyoneChip: some View {
        let isOn = selection == nil
        return Button {
            select(nil)
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "person.2.fill").font(.system(size: everyoneIconSize))
                    .accessibilityHidden(true)
                Text("Everyone").font(Typo.body(13, weight: .bold))
            }
            .foregroundStyle(isOn ? .white : Palette.slate)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(isOn ? Palette.indigo : Palette.elevated, in: Capsule())
            .overlay {
                Capsule().stroke(isOn ? Color.clear : Palette.mist, lineWidth: 1)
            }
            // Finding 1b: the ~30pt visual capsule sits centered in a 44pt
            // hit band (§6.5) — visuals unchanged, hit area compliant.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// UX audit finding 2: the selected state used to be white-on-raw-avatar
    /// -color, which falls under AA contrast for several avatar hues. Now
    /// ink-on-soft-tint — the same pairing `Today`/`TagChip`/
    /// `TZShiftChipRow` (ink-on-amberSoft) already use — with the person's
    /// own hue kept as the selected stroke so selection is still marked by
    /// more than just background shade.
    private func personChip(_ chip: Chip) -> some View {
        let isOn = selection == chip.id
        let color = AvatarColor.color(named: chip.colorName)
        return Button {
            select(chip.id)
        } label: {
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(color)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Text(chip.initial)
                            .font(Typo.body(10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .accessibilityHidden(true)
                Text(chip.firstName).font(Typo.body(13, weight: .bold))
            }
            .foregroundStyle(isOn ? Palette.ink : Palette.slate)
            .padding(.leading, 4)
            .padding(.trailing, Spacing.md)
            .padding(.vertical, 4)
            .background(isOn ? AvatarColor.softColor(named: chip.colorName) : Palette.elevated, in: Capsule())
            .overlay {
                Capsule().stroke(isOn ? color : Palette.mist, lineWidth: isOn ? 1.5 : 1)
            }
            // Finding 1b: same 44pt hit band as `everyoneChip` above.
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func select(_ id: UUID?) {
        UISelectionFeedbackGenerator().selectionChanged()
        selection = id
    }
}

/// The filter banner, shown only while a specific person is selected. Wording
/// is honest about the "unassigned = shared with everyone" model: it never
/// claims "just X's plans" when what's on screen is actually the whole group's
/// shared plans (persona dry-run: the old "Just Meera's plans — 43 of 43" read
/// as a lie).
struct PersonFilterBanner: View {
    let personFirstName: String
    let summary: PersonFilter.FilterSummary

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "sparkles").foregroundStyle(Palette.amber)
                .accessibilityHidden(true)
            Text(message)
                .font(Typo.body(Typo.Size.caption, weight: .semibold))
                .foregroundStyle(Palette.ink)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
        .background(Palette.amberSoft, in: RoundedRectangle(cornerRadius: Radii.card - 4, style: .continuous))
        .padding(.horizontal, Spacing.xl)
        .padding(.top, Spacing.sm)
    }

    private var message: String {
        let name = personFirstName
        if summary.assignedToPerson == 0 {
            guard summary.shared > 0 else { return "Nothing is assigned to \(name) yet." }
            let s = summary.shared
            return "Nothing just for \(name) yet \u{2014} showing \(s) plan\(s == 1 ? "" : "s") shared with everyone."
        }
        var parts = "\(summary.assignedToPerson) for \(name)"
        if summary.shared > 0 { parts += " \u{00B7} \(summary.shared) shared" }
        if summary.hiddenForOthers > 0 { parts += " \u{00B7} \(summary.hiddenForOthers) hidden" }
        return parts
    }
}

/// Finding 1's validate-first artifact: 8 chips, wide enough to overflow
/// on any iPhone width, pinning the trailing scrim's appearance.
#Preview("Overflowing chips") {
    let names = ["Priya", "Kiran", "Meera", "Arjun", "Sara", "Tom", "Ana", "Leo"]
    let colors = ["amber", "moss", "sky", "plum"]
    PersonFilterBar(
        chips: names.enumerated().map { index, name in
            .init(id: UUID(), firstName: name, initial: String(name.prefix(1)), colorName: colors[index % colors.count])
        },
        selection: .constant(nil)
    )
}

/// Companion case: only 2 chips, everything fits at rest — the scrim must
/// stay hidden here instead of showing as a standing decoration.
#Preview("Chips that fit") {
    PersonFilterBar(
        chips: [
            .init(id: UUID(), firstName: "Priya", initial: "P", colorName: "moss"),
            .init(id: UUID(), firstName: "Kiran", initial: "K", colorName: "plum")
        ],
        selection: .constant(nil)
    )
}
