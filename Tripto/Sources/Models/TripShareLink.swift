import Foundation
import SwiftData

/// Mirrors `public.share_links` — the no-app view-only link (BUILD_PLAN.md
/// §5.2). Named `TripShareLink`, not `ShareLink`: SwiftUI already defines a
/// `ShareLink` view (the share-sheet button), and shadowing it would bite
/// the moment M3's "Share with group" action row needs the real one.
/// Organizer-only via RLS for every verb, including SELECT: a
/// non-organizer's `pullTrip` legitimately gets back `[]` for this table,
/// which this app's sync layer must treat as a normal empty result, not an
/// error (M2/M3 build the sharing UI; M1 just mirrors the row shape).
@Model
final class TripShareLink {
    @Attribute(.unique) var id: UUID
    var tripId: UUID
    var token: String
    var scopeRaw: String
    var revoked: Bool
    var createdAt: Date

    init(
        id: UUID,
        tripId: UUID,
        token: String,
        scopeRaw: String,
        revoked: Bool,
        createdAt: Date
    ) {
        self.id = id
        self.tripId = tripId
        self.token = token
        self.scopeRaw = scopeRaw
        self.revoked = revoked
        self.createdAt = createdAt
    }

    var scope: ShareScope {
        get { ShareScope(rawValue: scopeRaw) ?? .view }
        set { scopeRaw = newValue.rawValue }
    }
}

struct ShareLinkDTO: Codable, Sendable, Equatable {
    var id: UUID
    var tripId: UUID
    var token: String
    var scope: String
    var revoked: Bool
    var createdAt: Date
}

extension TripShareLink {
    convenience init(dto: ShareLinkDTO) {
        self.init(
            id: dto.id,
            tripId: dto.tripId,
            token: dto.token,
            scopeRaw: dto.scope,
            revoked: dto.revoked,
            createdAt: dto.createdAt
        )
    }

    func apply(_ dto: ShareLinkDTO) {
        tripId = dto.tripId
        token = dto.token
        scopeRaw = dto.scope
        revoked = dto.revoked
        createdAt = dto.createdAt
    }

    func toDTO() -> ShareLinkDTO {
        ShareLinkDTO(
            id: id,
            tripId: tripId,
            token: token,
            scope: scopeRaw,
            revoked: revoked,
            createdAt: createdAt
        )
    }
}
