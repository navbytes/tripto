import Foundation
import SwiftData

/// Mirrors `public.trip_members` — the account-holding side of a trip's
/// roster (BUILD_PLAN.md §5.1 roles). Server-side RLS is the only real
/// security boundary (CLAUDE.md); this local mirror only drives
/// convenience UI like "hide the delete button for non-organizers".
@Model
final class TripMember {
    @Attribute(.unique) var id: UUID
    var tripId: UUID
    var userId: UUID
    var roleRaw: String
    var createdAt: Date

    init(
        id: UUID,
        tripId: UUID,
        userId: UUID,
        roleRaw: String,
        createdAt: Date
    ) {
        self.id = id
        self.tripId = tripId
        self.userId = userId
        self.roleRaw = roleRaw
        self.createdAt = createdAt
    }

    var role: TripRole {
        get { TripRole(rawValue: roleRaw) ?? .viewer }
        set { roleRaw = newValue.rawValue }
    }
}

struct TripMemberDTO: Codable, Sendable, Equatable {
    var id: UUID
    var tripId: UUID
    var userId: UUID
    var role: String
    var createdAt: Date
}

extension TripMember {
    convenience init(dto: TripMemberDTO) {
        self.init(
            id: dto.id,
            tripId: dto.tripId,
            userId: dto.userId,
            roleRaw: dto.role,
            createdAt: dto.createdAt
        )
    }

    func apply(_ dto: TripMemberDTO) {
        tripId = dto.tripId
        userId = dto.userId
        roleRaw = dto.role
        createdAt = dto.createdAt
    }

    func toDTO() -> TripMemberDTO {
        TripMemberDTO(id: id, tripId: tripId, userId: userId, role: roleRaw, createdAt: createdAt)
    }
}
