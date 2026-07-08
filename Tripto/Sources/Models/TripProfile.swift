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
    var linkedUserId: UUID?
    var createdAt: Date

    init(
        id: UUID,
        tripId: UUID,
        displayName: String,
        avatarColor: String,
        linkedUserId: UUID?,
        createdAt: Date
    ) {
        self.id = id
        self.tripId = tripId
        self.displayName = displayName
        self.avatarColor = avatarColor
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
            linkedUserId: dto.linkedUserId,
            createdAt: dto.createdAt
        )
    }

    func apply(_ dto: TripProfileDTO) {
        tripId = dto.tripId
        displayName = dto.displayName
        avatarColor = dto.avatarColor
        linkedUserId = dto.linkedUserId
        createdAt = dto.createdAt
    }

    func toDTO() -> TripProfileDTO {
        TripProfileDTO(
            id: id,
            tripId: tripId,
            displayName: displayName,
            avatarColor: avatarColor,
            linkedUserId: linkedUserId,
            createdAt: createdAt
        )
    }
}
