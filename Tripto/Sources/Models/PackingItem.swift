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

    /// TI-3: the local-insert-then-enqueue write shared by
    /// `PackingListView.addItem` and the new paste-import confirm flow
    /// (`PasteImportSheet`, reachable from any tab now, not just Packing —
    /// see that sheet's doc comment). Pulled out of `PackingListView` since
    /// packing items are trip-scoped data, not Packing-tab-scoped code; both
    /// call sites need the identical offline-first write (insert locally,
    /// save, enqueue for sync) with no duplicated logic to drift.
    @discardableResult
    static func insert(
        label: String,
        groupKey: PackingGroupKey,
        assigneeProfileId: UUID?,
        tripId: UUID,
        createdBy: UUID,
        modelContext: ModelContext,
        syncEngine: SyncEngine?
    ) -> PackingItem? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let now = Date()
        let item = PackingItem(
            id: UUID(), tripId: tripId, label: trimmed, groupKeyRaw: groupKey.rawValue,
            assigneeProfileId: assigneeProfileId, isDone: false, createdBy: createdBy,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        modelContext.insert(item)
        try? modelContext.save()
        let dto = item.toDTO()
        let rowId = item.id
        Task { await syncEngine?.enqueueUpsert(table: .packingItems, rowId: rowId, tripId: tripId, payload: dto) }
        return item
    }
}
