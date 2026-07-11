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
    var createdBy: UUID
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
        createdBy: UUID,
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
    var createdBy: UUID
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
