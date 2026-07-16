import Nuke
import NukeUI
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
        /// assignees phrase) and (P8a) this stack's own per-avatar
        /// accessibility label — `AvatarStack`'s sighted rendering is
        /// otherwise unaffected by it. Defaulted so existing call sites
        /// (`TripCard`/`HomeView.people(for:)`) keep compiling unchanged.
        var name: String = ""
        /// P8a (`.claude/company/ux-redesign/handoffs/P8-images-plan.md`
        /// D6): storage path, not URL — resolved to a public URL at render
        /// time via `AvatarStorage.publicURL(for:)`. `nil` (every existing
        /// call site, unaffected) renders exactly as before: initials on
        /// `colorName`, no photo attempted.
        var avatarPath: String?
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
                AvatarPhotoCircle(
                    initial: person.initial, colorName: person.colorName, avatarPath: person.avatarPath,
                    diameter: diameter, accessibilityName: person.name
                )
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

/// The one place an avatar photo actually renders (plan D6: "photos wrap
/// the existing one-seam renders") — shared by `AvatarStack` (per-person, in
/// a stack) and `AvatarPhotoPicker` (the single bigger preview on the two
/// profile-photo edit surfaces), so there's exactly one photo-with-fallback
/// implementation in the app.
///
/// Initials+`colorName` are ALWAYS drawn first — the immediate placeholder
/// AND the permanent, offline-never-blank fallback (P8a brief) — with a Nuke
/// `LazyImage` layered on top that only ever covers them on a successful
/// load. A slow/uncached/offline photo simply never covers the initials, so
/// this can never render blank.
struct AvatarPhotoCircle: View {
    let initial: String
    let colorName: String
    let avatarPath: String?
    var diameter: CGFloat = 26
    /// VoiceOver label for this one avatar — a person's name, never "Image"
    /// (P8a brief's a11y note): `.accessibilityElement(children: .ignore)`
    /// collapses the initials `Text` and the photo `Image` into one element
    /// so a photo is never announced as a second, separate item. Falls back
    /// to the bare initial for the few callers with no name to give
    /// (`AvatarStack.Person.name`'s own doc comment) — same reasoning as
    /// `TimelineRowViews.assigneesPhrase`'s own fallback.
    var accessibilityName: String = ""

    var body: some View {
        Circle()
            .fill(AvatarColor.color(named: colorName))
            .frame(width: diameter, height: diameter)
            .overlay {
                Text(initial)
                    .font(Typo.body(diameter * 0.42, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay {
                // `AppImagePipeline.configured` swaps in the
                // DataCache-backed pipeline `LazyImage` reads by default,
                // exactly once, before the first photo load this app ever
                // attempts (P8b: renamed from `AvatarImagePipeline` — it
                // configures the one shared pipeline every `LazyImage`
                // reads, avatar or cover).
                if let avatarPath, AppImagePipeline.configured, let url = AvatarStorage.publicURL(for: avatarPath) {
                    LazyImage(url: url) { state in
                        if let image = state.image {
                            image.resizable().scaledToFill()
                        }
                        // `.empty`/`.failure` intentionally render nothing —
                        // the initials underneath already show through.
                    }
                    // Reviewer D3: without this, every distinct avatar in a
                    // list/stack decodes the full ~512px stored JPEG into a
                    // full-size bitmap just to draw an 18-26pt circle —
                    // `.resize` downsamples at decode time (keyed to this
                    // circle's own `diameter`), same "never decode bigger
                    // than you'll render" reasoning as `ImageProcessing`'s
                    // own upload-side downsample.
                    .processors([ImageProcessors.Resize(size: CGSize(width: diameter, height: diameter), contentMode: .aspectFill, crop: true)])
                    .frame(width: diameter, height: diameter)
                    .clipShape(Circle())
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityName.isEmpty ? initial : accessibilityName)
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
