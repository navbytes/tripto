import Foundation
import SwiftData

/// Mirrors `public.invites` — role-carrying join links claimed via
/// `claim_invite(token)` (RESEARCH_FINDINGS.md amendment #3, replacing
/// plain email invites). Same "organizer-only, `[]` for everyone else"
/// RLS shape as `TripShareLink` — see that type's doc comment.
@Model
final class Invite {
    @Attribute(.unique) var id: UUID
    var tripId: UUID
    var token: String
    var roleRaw: String
    var createdBy: UUID
    var createdAt: Date
    var expiresAt: Date
    var revoked: Bool

    init(
        id: UUID,
        tripId: UUID,
        token: String,
        roleRaw: String,
        createdBy: UUID,
        createdAt: Date,
        expiresAt: Date,
        revoked: Bool
    ) {
        self.id = id
        self.tripId = tripId
        self.token = token
        self.roleRaw = roleRaw
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.revoked = revoked
    }

    /// Invite roles exclude `organizer` server-side (`invites.role check
    /// (role in ('companion','viewer'))`) — falls back to `.viewer` for any
    /// unrecognized value, same defensive pattern as the other role enums.
    var role: TripRole {
        get { TripRole(rawValue: roleRaw) ?? .viewer }
        set { roleRaw = newValue.rawValue }
    }
}

struct InviteDTO: Codable, Sendable, Equatable {
    var id: UUID
    var tripId: UUID
    var token: String
    var role: String
    var createdBy: UUID
    var createdAt: Date
    var expiresAt: Date
    var revoked: Bool
}

extension Invite {
    convenience init(dto: InviteDTO) {
        self.init(
            id: dto.id,
            tripId: dto.tripId,
            token: dto.token,
            roleRaw: dto.role,
            createdBy: dto.createdBy,
            createdAt: dto.createdAt,
            expiresAt: dto.expiresAt,
            revoked: dto.revoked
        )
    }

    func apply(_ dto: InviteDTO) {
        tripId = dto.tripId
        token = dto.token
        roleRaw = dto.role
        createdBy = dto.createdBy
        createdAt = dto.createdAt
        expiresAt = dto.expiresAt
        revoked = dto.revoked
    }

    func toDTO() -> InviteDTO {
        InviteDTO(
            id: id,
            tripId: tripId,
            token: token,
            role: roleRaw,
            createdBy: createdBy,
            createdAt: createdAt,
            expiresAt: expiresAt,
            revoked: revoked
        )
    }
}
