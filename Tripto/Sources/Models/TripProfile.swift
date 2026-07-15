import Foundation
import SwiftData

/// Mirrors `public.trip_profiles` — everyone on a trip, account or not
/// (BUILD_PLAN.md §3.3 "non-app family members"; §5.3). `linkedUserId` is
/// set when this profile belongs to someone who also has a `Profile`
/// (account); nil for a kid or grandparent with no account. Avatar
/// stacks/assignee pickers (M2+) read from this table, never from
/// `TripMember` directly.
@Model
final class TripProfile {
    @Attribute(.unique) var id: UUID
    var tripId: UUID
    var displayName: String
    var avatarColor: String
    /// `trip_profiles.avatar_path` — see `Profile.avatarPath`'s doc comment
    /// for the path-not-URL/nullable/additive reasoning, identical here.
    /// Uploaded by whichever organizer is editing this profile (their own
    /// linked one, or any no-account kid/grandparent's) — `AvatarStorage`'s
    /// owner-folder path always keys off the *uploader's* `auth.uid()`, not
    /// this row's (possibly absent, for a no-account profile) `linkedUserId`.
    var avatarPath: String?
    var linkedUserId: UUID?
    var createdAt: Date

    init(
        id: UUID,
        tripId: UUID,
        displayName: String,
        avatarColor: String,
        avatarPath: String? = nil,
        linkedUserId: UUID?,
        createdAt: Date
    ) {
        self.id = id
        self.tripId = tripId
        self.displayName = displayName
        self.avatarColor = avatarColor
        self.avatarPath = avatarPath
        self.linkedUserId = linkedUserId
        self.createdAt = createdAt
    }
}

/// Explicit, since `@Model` doesn't synthesize this (see `Trip`'s identical
/// comment) — `ShareTripView` renders unlinked (no-account) profiles in a
/// `ForEach`.
extension TripProfile: Identifiable {}

struct TripProfileDTO: Codable, Sendable, Equatable {
    var id: UUID
    var tripId: UUID
    var displayName: String
    var avatarColor: String
    /// See `TripProfile.avatarPath`'s doc comment; defaulted for the same
    /// "absent server column / plain memberwise init" reasons as
    /// `ProfileDTO.avatarPath`.
    var avatarPath: String?
    var linkedUserId: UUID?
    var createdAt: Date
}

extension TripProfile {
    convenience init(dto: TripProfileDTO) {
        self.init(
            id: dto.id,
            tripId: dto.tripId,
            displayName: dto.displayName,
            avatarColor: dto.avatarColor,
            avatarPath: dto.avatarPath,
            linkedUserId: dto.linkedUserId,
            createdAt: dto.createdAt
        )
    }

    func apply(_ dto: TripProfileDTO) {
        tripId = dto.tripId
        displayName = dto.displayName
        avatarColor = dto.avatarColor
        avatarPath = dto.avatarPath
        linkedUserId = dto.linkedUserId
        createdAt = dto.createdAt
    }

    func toDTO() -> TripProfileDTO {
        TripProfileDTO(
            id: id,
            tripId: tripId,
            displayName: displayName,
            avatarColor: avatarColor,
            avatarPath: avatarPath,
            linkedUserId: linkedUserId,
            createdAt: createdAt
        )
    }
}
