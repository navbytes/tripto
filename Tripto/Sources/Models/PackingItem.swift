import Foundation
import SwiftData

/// Mirrors `public.packing_items`. Like `ItineraryItem`, M1 only needs this
/// to round-trip through sync — the shared packing list UI is M4.
@Model
final class PackingItem {
    @Attribute(.unique) var id: UUID
    var tripId: UUID
    var label: String
    var groupKeyRaw: String
    var assigneeProfileId: UUID?
    var isDone: Bool
    var createdBy: UUID
    var createdAt: Date
    var updatedAt: Date
    var updatedBy: UUID?

    init(
        id: UUID,
        tripId: UUID,
        label: String,
        groupKeyRaw: String,
        assigneeProfileId: UUID?,
        isDone: Bool,
        createdBy: UUID,
        createdAt: Date,
        updatedAt: Date,
        updatedBy: UUID?
    ) {
        self.id = id
        self.tripId = tripId
        self.label = label
        self.groupKeyRaw = groupKeyRaw
        self.assigneeProfileId = assigneeProfileId
        self.isDone = isDone
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    var groupKey: PackingGroupKey {
        get { PackingGroupKey(rawValue: groupKeyRaw) ?? .custom }
        set { groupKeyRaw = newValue.rawValue }
    }
}

struct PackingItemDTO: Codable, Sendable, Equatable {
    var id: UUID
    var tripId: UUID
    var label: String
    var groupKey: String
    var assigneeProfileId: UUID?
    var isDone: Bool
    var createdBy: UUID
    var createdAt: Date
    var updatedAt: Date
    var updatedBy: UUID?
}

extension PackingItem {
    convenience init(dto: PackingItemDTO) {
        self.init(
            id: dto.id,
            tripId: dto.tripId,
            label: dto.label,
            groupKeyRaw: dto.groupKey,
            assigneeProfileId: dto.assigneeProfileId,
            isDone: dto.isDone,
            createdBy: dto.createdBy,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            updatedBy: dto.updatedBy
        )
    }

    func apply(_ dto: PackingItemDTO) {
        tripId = dto.tripId
        label = dto.label
        groupKeyRaw = dto.groupKey
        assigneeProfileId = dto.assigneeProfileId
        isDone = dto.isDone
        createdBy = dto.createdBy
        createdAt = dto.createdAt
        updatedAt = dto.updatedAt
        updatedBy = dto.updatedBy
    }

    func toDTO() -> PackingItemDTO {
        PackingItemDTO(
            id: id,
            tripId: tripId,
            label: label,
            groupKey: groupKeyRaw,
            assigneeProfileId: assigneeProfileId,
            isDone: isDone,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            updatedBy: updatedBy
        )
    }
}
