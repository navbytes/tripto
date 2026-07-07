import SwiftUI

/// Maps the server's `avatar_color` string (`profiles.avatar_color`,
/// `trip_profiles.avatar_color` — "amber"/"moss"/"sky"/"plum" per
/// `handle_new_user`'s seed palette, BUILD_PLAN.md §6.1) to a token color.
/// These are the same four hues `CategoryColor` already defines for
/// itinerary categories, just addressed by color name instead of category
/// name here — this file is hand-written and only ever reads from the
/// generated `Tokens.swift`, never repeats a hex literal.
enum AvatarColor {
    static func color(named name: String) -> Color {
        switch name.lowercased() {
        case "amber": CategoryColor.hotel.fg
        case "moss": CategoryColor.activity.fg
        case "sky": CategoryColor.flight.fg
        case "plum": CategoryColor.food.fg
        default: Palette.slate
        }
    }
}
