import SwiftUI

/// Overlapping avatar circles for a trip's members/assignees (BUILD_PLAN.md
/// §6.3 signature elements, §6.4 component list). Initials + `avatar_color`
/// come from `TripProfile`, never from `TripMember` directly — a
/// `TripProfile` exists for everyone on the trip, account or not.
struct AvatarStack: View {
    struct Person: Identifiable {
        let id: UUID
        let initial: String
        let colorName: String
    }

    let people: [Person]
    var maxVisible: Int = 3
    var diameter: CGFloat = 26

    var body: some View {
        HStack(spacing: -diameter * 0.35) {
            ForEach(Array(people.prefix(maxVisible))) { person in
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
        }
    }
}

#Preview {
    AvatarStack(people: [
        .init(id: UUID(), initial: "N", colorName: "amber"),
        .init(id: UUID(), initial: "P", colorName: "moss"),
        .init(id: UUID(), initial: "K", colorName: "plum"),
        .init(id: UUID(), initial: "M", colorName: "sky"),
    ])
    .padding(Spacing.xl)
    .background(Palette.paper)
}
