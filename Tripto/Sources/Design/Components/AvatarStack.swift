import SwiftUI

/// Overlapping avatar circles for a trip's members/assignees (BUILD_PLAN.md
/// §6.3 signature elements, §6.4 component list). Initials + `avatar_color`
/// come from `TripProfile`, never from `TripMember` directly — a
/// `TripProfile` exists for everyone on the trip, account or not.
struct AvatarStack: View {
    /// `Equatable` so it can ride inside the timeline's value-snapshot row
    /// models (`TimelineCardModel.assignees`, §7.2's "Equatable row views
    /// over value snapshots" — see `TimelineRowViews.swift`'s doc comment).
    struct Person: Identifiable, Equatable {
        let id: UUID
        let initial: String
        let colorName: String
        /// Finding F4: exists for spoken labels (`TimelineCardRow`'s
        /// assignees phrase), not for display — `AvatarStack`'s own
        /// rendering below is initials-only and never reads this. Defaulted
        /// so existing call sites (`TripCard`/`HomeView.people(for:)`) keep
        /// compiling unchanged.
        var name: String = ""
    }

    let people: [Person]
    var maxVisible: Int = 3
    var diameter: CGFloat = 26

    /// How many people are hidden behind the trailing "+N" chip (finding
    /// 6). Kept as an internal helper — over `maxVisible` people, one
    /// visible slot is traded for the overflow chip so the total circle
    /// count (and thus the stack's width) never changes: a 6-person trip at
    /// `maxVisible` 3 shows 2 avatars + "+4", not 3 avatars + "+3".
    static func overflowCount(peopleCount: Int, maxVisible: Int) -> Int {
        peopleCount > maxVisible ? peopleCount - (maxVisible - 1) : 0
    }

    private var overflowCount: Int {
        AvatarStack.overflowCount(peopleCount: people.count, maxVisible: maxVisible)
    }

    private var visiblePeople: ArraySlice<Person> {
        people.prefix(overflowCount > 0 ? maxVisible - 1 : maxVisible)
    }

    var body: some View {
        HStack(spacing: -diameter * 0.35) {
            ForEach(Array(visiblePeople)) { person in
                Circle()
                    .fill(AvatarColor.color(named: person.colorName))
                    .frame(width: diameter, height: diameter)
                    .overlay {
                        Text(person.initial)
                            .font(Typo.body(diameter * 0.42, weight: .bold))
                            .foregroundStyle(.white)
                    }
                    .overlay {
                        Circle().stroke(.white.opacity(0.9), lineWidth: 2)
                    }
            }
            // Sighted users previously saw fewer avatars than VoiceOver's
            // spoken count implied (a 6-person trip read as 3-person); this
            // chip closes that gap without widening the stack.
            if overflowCount > 0 {
                Circle()
                    .fill(Palette.slate)
                    .frame(width: diameter, height: diameter)
                    .overlay {
                        Text("+\(overflowCount)")
                            .font(Typo.body(diameter * 0.42, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .overlay {
                        Circle().stroke(.white.opacity(0.9), lineWidth: 2)
                    }
            }
        }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: Spacing.lg) {
        AvatarStack(people: [
            .init(id: UUID(), initial: "N", colorName: "amber"),
            .init(id: UUID(), initial: "P", colorName: "moss")
        ])
        AvatarStack(people: [
            .init(id: UUID(), initial: "N", colorName: "amber"),
            .init(id: UUID(), initial: "P", colorName: "moss"),
            .init(id: UUID(), initial: "K", colorName: "plum"),
            .init(id: UUID(), initial: "M", colorName: "sky")
        ])
        // 6 people at the default maxVisible of 3 (finding 6): 2 avatars +
        // a "+4" overflow chip, total circle count still 3.
        AvatarStack(people: [
            .init(id: UUID(), initial: "N", colorName: "amber"),
            .init(id: UUID(), initial: "P", colorName: "moss"),
            .init(id: UUID(), initial: "K", colorName: "plum"),
            .init(id: UUID(), initial: "M", colorName: "sky"),
            .init(id: UUID(), initial: "S", colorName: "amber"),
            .init(id: UUID(), initial: "T", colorName: "moss")
        ])
    }
    .padding(Spacing.xl)
    .background(Palette.paper)
}
