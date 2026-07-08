import SwiftUI

/// The "Just mine" person filter atop the itinerary (BUILD_PLAN.md §5.4;
/// docs/TripAppFamily.jsx's `JustMine` screen is the visual reference):
/// "Everyone" + one chip per `TripProfile`, horizontal scroll. `TripView`
/// owns the actual filtering (`PersonFilter.filteredItems`) and the
/// selection state (`nil` = Everyone) — this is a pure renderer.
struct PersonFilterBar: View {
    struct Chip: Identifiable {
        let id: UUID
        let firstName: String
        let initial: String
        let colorName: String
    }

    let chips: [Chip]
    @Binding var selection: UUID?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .bold))
                Text("Showing plans for")
                    .font(Typo.body(11, weight: .bold))
                    .tracking(0.4)
            }
            .foregroundStyle(Palette.slate)
            .textCase(.uppercase)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    everyoneChip
                    ForEach(chips) { chip in
                        personChip(chip)
                    }
                }
                .padding(.trailing, Spacing.xl)
            }
        }
        .padding(.horizontal, Spacing.xl)
        .padding(.vertical, Spacing.md)
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
                Image(systemName: "person.2.fill").font(.system(size: 12))
                Text("Everyone").font(Typo.body(13, weight: .bold))
            }
            .foregroundStyle(isOn ? .white : Palette.slate)
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
            .background(isOn ? Palette.indigo : Palette.elevated, in: Capsule())
            .overlay {
                Capsule().stroke(isOn ? Color.clear : Palette.mist, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func personChip(_ chip: Chip) -> some View {
        let isOn = selection == chip.id
        let color = AvatarColor.color(named: chip.colorName)
        return Button {
            select(chip.id)
        } label: {
            HStack(spacing: Spacing.xs) {
                Circle()
                    .fill(isOn ? .white.opacity(0.28) : color)
                    .frame(width: 22, height: 22)
                    .overlay {
                        Text(chip.initial)
                            .font(Typo.body(10, weight: .bold))
                            .foregroundStyle(.white)
                    }
                Text(chip.firstName).font(Typo.body(13, weight: .bold))
            }
            .foregroundStyle(isOn ? .white : Palette.slate)
            .padding(.leading, 4)
            .padding(.trailing, Spacing.md)
            .padding(.vertical, 4)
            .background(isOn ? color : Palette.elevated, in: Capsule())
            .overlay {
                Capsule().stroke(isOn ? Color.clear : Palette.mist, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    private func select(_ id: UUID?) {
        UISelectionFeedbackGenerator().selectionChanged()
        selection = id
    }
}

/// "Just Meera's plans — 4 of 12 items" (this milestone's brief; the
/// mockup's amber Sparkles banner) — `TripView` shows this only while a
/// specific person is selected.
struct PersonFilterBanner: View {
    let personFirstName: String
    let visibleCount: Int
    let totalCount: Int

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "sparkles").foregroundStyle(Palette.amber)
            Text("Just \(personFirstName)\u{2019}s plans \u{2014} \(visibleCount) of \(totalCount) item\(totalCount == 1 ? "" : "s")")
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
}
