import Foundation
import SwiftData

/// Mirrors `public.profiles` — one row per `auth.users` account (CLAUDE.md
/// "every table is RLS deny-by-default"; this one seeds itself via the
/// backend's `handle_new_user` trigger). Not the same thing as
/// `TripProfile`: a `Profile` only exists for people with an account; a
/// `TripProfile` exists for anyone on a trip, account or not (BUILD_PLAN.md
/// §3.3 "non-app family members").
@Model
final class Profile {
    @Attribute(.unique) var id: UUID
    var displayName: String
    var avatarColor: String
    var createdAt: Date
    var updatedAt: Date

    init(
        id: UUID,
        displayName: String,
        avatarColor: String,
        createdAt: Date,
        updatedAt: Date
    ) {
        self.id = id
        self.displayName = displayName
        self.avatarColor = avatarColor
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Wire shape for `profiles` — see `JSONCoding` for the snake_case + ISO8601
/// mechanism this decodes/encodes against.
struct ProfileDTO: Codable, Sendable, Equatable {
    var id: UUID
    var displayName: String
    var avatarColor: String
    var createdAt: Date
    var updatedAt: Date
}

extension Profile {
    convenience init(dto: ProfileDTO) {
        self.init(
            id: dto.id,
            displayName: dto.displayName,
            avatarColor: dto.avatarColor,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt
        )
    }

    /// Updates every mirrored field in place from a freshly-pulled DTO.
    /// Used by pull-apply when a local row already exists for this id.
    func apply(_ dto: ProfileDTO) {
        displayName = dto.displayName
        avatarColor = dto.avatarColor
        createdAt = dto.createdAt
        updatedAt = dto.updatedAt
    }

    func toDTO() -> ProfileDTO {
        ProfileDTO(
            id: id,
            displayName: displayName,
            avatarColor: avatarColor,
            createdAt: createdAt,
            updatedAt: updatedAt
        )
    }
}
