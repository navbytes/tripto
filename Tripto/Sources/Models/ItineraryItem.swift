import Foundation
import Supabase
import SwiftData

/// Mirrors `public.itinerary_items`. M1 only needs this table to exist and
/// round-trip correctly (SYNC_DESIGN.md mirrors all 8 tables from M1 even
/// though the timeline UI is M2) — `HomeView` never renders one of these.
///
/// `startsAt`/`endsAt` are genuine `timestamptz` instants (unlike
/// `Trip.startDate`/`endDate`): store UTC, keep `tz` alongside, and defer
/// all "display in the item's local time" logic to M2 (BUILD_PLAN.md
/// §7.4; ACCEPTANCE.md "(a)"). `details` is the category-specific JSONB
/// blob (flight/hotel/activity/food fields, BUILD_PLAN.md §3.3) — stored
/// locally as its compact JSON text so SwiftData doesn't need an `AnyJSON`
/// attribute, and round-tripped losslessly through `AnyJSON` at the
/// DTO/Model boundary (see `detailsJSON`/`ItineraryItemDTO.details`).
@Model
final class ItineraryItem {
    @Attribute(.unique) var id: UUID
    var tripId: UUID
    var categoryRaw: String
    var title: String
    var startsAt: Date
    var endsAt: Date?
    var tz: String
    var locationName: String
    var locationLat: Double?
    var locationLng: Double?
    var confirmation: String?
    var notes: String?
    /// Compact JSON text of the `details` jsonb column — see type doc comment.
    var detailsJSON: String
    var statusRaw: String
    /// `itinerary_items.source` (`Models/Enums.swift`'s `ItemSource` doc
    /// comment). Defaulted at both the property and the initializer —
    /// mirrors `SyncIssue.retriable`'s doc comment — so adding this column
    /// is a purely additive, lightweight-migration-safe change: an
    /// already-installed app's existing local rows simply read "manual" on
    /// next launch, the same value the server itself defaults absent one.
    var sourceRaw: String = ItemSource.manual.rawValue
    /// `itinerary_items.sender_verified` (EI-4) — additive/nullable,
    /// same purely-additive, lightweight-migration-safe pattern as
    /// `sourceRaw` above: an already-installed app's existing local rows
    /// simply read `nil` on next launch. `nil` means not applicable (a
    /// manual/paste-imported item, or a row pulled before this column
    /// existed server-side); `false` means the item arrived via a
    /// forwarded email and the forwarder isn't a member of this trip;
    /// `true` means they are. Only `false` is ever surfaced in the UI —
    /// see `isFromUnverifiedSender`.
    var senderVerified: Bool?
    /// Nullable since the F3 account-deletion migration
    /// (`ON DELETE SET NULL`): an item a since-departed user added to
    /// someone else's trip survives with `createdBy == nil` rather than
    /// cascading away. Never treat `nil` as "mine" — see
    /// `ItemPermissions.canEdit`.
    var createdBy: UUID?
    var createdAt: Date
    var updatedAt: Date
    var updatedBy: UUID?

    init(
        id: UUID,
        tripId: UUID,
        categoryRaw: String,
        title: String,
        startsAt: Date,
        endsAt: Date?,
        tz: String,
        locationName: String,
        locationLat: Double?,
        locationLng: Double?,
        confirmation: String?,
        notes: String?,
        detailsJSON: String,
        statusRaw: String,
        sourceRaw: String = ItemSource.manual.rawValue,
        senderVerified: Bool? = nil,
        createdBy: UUID?,
        createdAt: Date,
        updatedAt: Date,
        updatedBy: UUID?
    ) {
        self.id = id
        self.tripId = tripId
        self.categoryRaw = categoryRaw
        self.title = title
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.tz = tz
        self.locationName = locationName
        self.locationLat = locationLat
        self.locationLng = locationLng
        self.confirmation = confirmation
        self.notes = notes
        self.detailsJSON = detailsJSON
        self.statusRaw = statusRaw
        self.sourceRaw = sourceRaw
        self.senderVerified = senderVerified
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    var category: ItemCategory {
        get { ItemCategory(rawValue: categoryRaw) ?? .activity }
        set { categoryRaw = newValue.rawValue }
    }

    var status: ItemStatus {
        get { ItemStatus(rawValue: statusRaw) ?? .confirmed }
        set { statusRaw = newValue.rawValue }
    }

    var source: ItemSource {
        get { ItemSource(rawValue: sourceRaw) ?? .manual }
        set { sourceRaw = newValue.rawValue }
    }

    /// EI-4: the one predicate `SuggestedItemsSheet`'s row badge and
    /// `AddItemSheet`'s review-mode callout both key off, so the two can't
    /// drift out of sync with each other. Deliberately `== false`, not
    /// `!= true`: `nil` ("not applicable" — see `senderVerified`'s doc
    /// comment) must never badge, only a confirmed "forwarder isn't a
    /// trip member" `false` does.
    var isFromUnverifiedSender: Bool { senderVerified == false }

    /// DBG-bookings: the single definition of "is this a booking," replacing
    /// the two definitions that never met — the import pipeline's `status`
    /// lifecycle and `BookingsTabView`'s old bare `confirmation != ""` check.
    /// A flight/hotel/transport item is always a booking (BUILD_PLAN §4.4's
    /// boarding-pass intent); any other category counts only if it carries a
    /// real reservation marker, so a plain sightseeing stop doesn't. Checks
    /// `details.ticketRef`/`details.reservationName` (`ItineraryItem+Details
    /// .swift`) as well as the top-level `confirmation` column, since a
    /// paste-imported activity/food item can carry its marker there instead.
    ///
    /// Deliberately status-agnostic — `suggested` items are excluded upstream
    /// by `TripView`'s own `@Query` predicate before either trusted tab ever
    /// sees `items`, so filtering status here too would double-filter.
    var isBooking: Bool {
        switch category {
        case .flight, .hotel, .transport:
            return true
        case .activity, .food:
            return !(confirmation ?? "").isEmpty
                || !(details.ticketRef ?? "").isEmpty
                || !(details.reservationName ?? "").isEmpty
        }
    }
}

struct ItineraryItemDTO: Codable, Sendable, Equatable {
    var id: UUID
    var tripId: UUID
    var category: String
    var title: String
    var startsAt: Date
    var endsAt: Date?
    var tz: String
    var locationName: String
    var locationLat: Double?
    var locationLng: Double?
    var confirmation: String?
    var notes: String?
    var details: AnyJSON
    var status: String
    /// `Models/Enums.swift`'s `ItemSource` doc comment. Defaulted so
    /// existing call sites/fixtures that predate this column (built via the
    /// plain memberwise init, not decoded off the wire) keep compiling
    /// unchanged — real PostgREST rows always carry a value (`not null
    /// default 'manual'`), so this default only ever matters for those.
    var source: String = ItemSource.manual.rawValue
    /// `itinerary_items.sender_verified` — see `ItineraryItem.senderVerified`'s
    /// doc comment for the tri-state meaning. An ordinary `Bool?` already
    /// decodes fine whether the key is entirely absent (server hasn't
    /// shipped the column yet) or explicitly `null` (`decodeIfPresent`
    /// handles both), and defaults to `nil` here too so a DTO built via the
    /// plain memberwise init (rather than decoded off the wire) keeps
    /// compiling unchanged.
    var senderVerified: Bool?
    var createdBy: UUID?
    var createdAt: Date
    var updatedAt: Date
    var updatedBy: UUID?
}

extension ItineraryItem {
    convenience init(dto: ItineraryItemDTO) {
        self.init(
            id: dto.id,
            tripId: dto.tripId,
            categoryRaw: dto.category,
            title: dto.title,
            startsAt: dto.startsAt,
            endsAt: dto.endsAt,
            tz: dto.tz,
            locationName: dto.locationName,
            locationLat: dto.locationLat,
            locationLng: dto.locationLng,
            confirmation: dto.confirmation,
            notes: dto.notes,
            detailsJSON: dto.details.jsonText,
            statusRaw: dto.status,
            sourceRaw: dto.source,
            senderVerified: dto.senderVerified,
            createdBy: dto.createdBy,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            updatedBy: dto.updatedBy
        )
    }

    func apply(_ dto: ItineraryItemDTO) {
        tripId = dto.tripId
        categoryRaw = dto.category
        title = dto.title
        startsAt = dto.startsAt
        endsAt = dto.endsAt
        tz = dto.tz
        locationName = dto.locationName
        locationLat = dto.locationLat
        locationLng = dto.locationLng
        confirmation = dto.confirmation
        notes = dto.notes
        detailsJSON = dto.details.jsonText
        statusRaw = dto.status
        sourceRaw = dto.source
        senderVerified = dto.senderVerified
        createdBy = dto.createdBy
        createdAt = dto.createdAt
        updatedAt = dto.updatedAt
        updatedBy = dto.updatedBy
    }

    func toDTO() -> ItineraryItemDTO {
        ItineraryItemDTO(
            id: id,
            tripId: tripId,
            category: categoryRaw,
            title: title,
            startsAt: startsAt,
            endsAt: endsAt,
            tz: tz,
            locationName: locationName,
            locationLat: locationLat,
            locationLng: locationLng,
            confirmation: confirmation,
            notes: notes,
            details: AnyJSON(jsonText: detailsJSON),
            status: statusRaw,
            source: sourceRaw,
            senderVerified: senderVerified,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            updatedBy: updatedBy
        )
    }
}

extension AnyJSON {
    /// Round-trips through `JSONCoding`'s *passthrough* coders — a
    /// `details` blob's keys (`flight_no`, `check_in`, ...) are opaque
    /// content, not Swift property names, so they must survive byte-for-byte
    /// rather than going through `.convertToSnakeCase`/`.convertFromSnakeCase`
    /// a second time. See `JSONCoding.passthroughDecoder`'s doc comment.
    var jsonText: String {
        (try? String(data: JSONCoding.passthroughEncoder.encode(self), encoding: .utf8)) ?? "{}"
    }

    init(jsonText: String) {
        guard let data = jsonText.data(using: .utf8),
            let decoded = try? JSONCoding.passthroughDecoder.decode(AnyJSON.self, from: data)
        else {
            self = .object([:])
            return
        }
        self = decoded
    }
}
