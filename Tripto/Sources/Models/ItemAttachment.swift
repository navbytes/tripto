import Foundation
import SwiftData

/// Mirrors `public.item_attachments` (release 1.2, `docs/PRODUCT_PLAN.md`
/// §2.1 — "every booking carries its paper"): the images/PDFs (boarding
/// passes, vouchers, tickets) a trip member attaches to one itinerary item.
/// See `.claude/company/release-1.2/PLAN.md` C1 for the frozen schema this
/// mirrors, and `Data/AttachmentService.swift`/`Data/AttachmentStorage.swift`
/// for the upload/download halves.
///
/// Immutable server-side (insert/delete only, no `updated_at` — C1). Unlike
/// every other mirrored row in this app there is no in-place edit path at
/// all, so `apply(_:)` below only ever runs during pull-apply upsert — kept
/// for symmetry with every sibling model's `apply(_:)` so `SyncStore
/// .applyItemAttachments` can follow the exact same upsert-by-id shape as
/// the rest of `SyncStore+Apply.swift` (`ItemAssignee`'s doc comment makes
/// the identical call for its own immutable-in-practice case).
@Model
final class ItemAttachment {
    @Attribute(.unique) var id: UUID
    var tripId: UUID
    var itemId: UUID
    /// The original file name (e.g. "boarding-pass.pdf") — never the on-disk
    /// cache name or the storage object's own uuid-based path segment. Shown
    /// in the QuickLook nav bar (`Support/QuickLookPreview.swift`) and
    /// spoken by VoiceOver (`AttachmentStrip`'s per-thumbnail label).
    var fileName: String
    var contentTypeRaw: String
    var byteSize: Int
    /// `'<tripId>/<itemId>/<uuid>.<jpg|pdf>'` in the private `item-attachments`
    /// bucket — never a public URL (`AttachmentStorage`'s doc comment).
    var storagePath: String
    /// Nullable since the uploader's account can be deleted after the fact
    /// (`ON DELETE SET NULL`, the same F3 survivorship convention as
    /// `ItineraryItem.createdBy`/`PackingItem.createdBy` — see either's doc
    /// comment). Never treat `nil` as "mine" for the delete affordance; see
    /// `AttachmentStrip.canDelete`.
    var createdBy: UUID?
    var createdAt: Date

    init(
        id: UUID,
        tripId: UUID,
        itemId: UUID,
        fileName: String,
        contentTypeRaw: String,
        byteSize: Int,
        storagePath: String,
        createdBy: UUID?,
        createdAt: Date
    ) {
        self.id = id
        self.tripId = tripId
        self.itemId = itemId
        self.fileName = fileName
        self.contentTypeRaw = contentTypeRaw
        self.byteSize = byteSize
        self.storagePath = storagePath
        self.createdBy = createdBy
        self.createdAt = createdAt
    }

    var contentType: AttachmentContentType {
        get { AttachmentContentType(rawValue: contentTypeRaw) ?? .jpeg }
        set { contentTypeRaw = newValue.rawValue }
    }
}

/// Explicit, since `@Model` doesn't synthesize this (see `Trip`'s identical
/// comment) — attachments render in `ForEach` (`AttachmentStrip`).
extension ItemAttachment: Identifiable {}

/// Wire shape for `item_attachments`.
struct ItemAttachmentDTO: Codable, Sendable, Equatable {
    var id: UUID
    var tripId: UUID
    var itemId: UUID
    var fileName: String
    var contentType: String
    var byteSize: Int
    var storagePath: String
    var createdBy: UUID?
    var createdAt: Date
}

extension ItemAttachment {
    convenience init(dto: ItemAttachmentDTO) {
        self.init(
            id: dto.id,
            tripId: dto.tripId,
            itemId: dto.itemId,
            fileName: dto.fileName,
            contentTypeRaw: dto.contentType,
            byteSize: dto.byteSize,
            storagePath: dto.storagePath,
            createdBy: dto.createdBy,
            createdAt: dto.createdAt
        )
    }

    func apply(_ dto: ItemAttachmentDTO) {
        tripId = dto.tripId
        itemId = dto.itemId
        fileName = dto.fileName
        contentTypeRaw = dto.contentType
        byteSize = dto.byteSize
        storagePath = dto.storagePath
        createdBy = dto.createdBy
        createdAt = dto.createdAt
    }

    func toDTO() -> ItemAttachmentDTO {
        ItemAttachmentDTO(
            id: id,
            tripId: tripId,
            itemId: itemId,
            fileName: fileName,
            contentType: contentTypeRaw,
            byteSize: byteSize,
            storagePath: storagePath,
            createdBy: createdBy,
            createdAt: createdAt
        )
    }
}

/// File extension used for both the disk cache's filename (`AttachmentStore`)
/// and the storage object's own path suffix (`AttachmentStorage.path`) — the
/// two places C1's `'<uuid>.<jpg|pdf>'` naming rule actually matters.
extension AttachmentContentType {
    var fileExtension: String {
        switch self {
        case .jpeg: return "jpg"
        case .pdf: return "pdf"
        }
    }
}
