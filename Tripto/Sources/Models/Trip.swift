import Foundation
import SwiftData

/// Mirrors `public.trips`. `startDate`/`endDate` are stored as the
/// local-midnight `Date` for that calendar day (see `DayDate`) — plain
/// wall-calendar days, not `timestamptz` instants, so there is no time zone
/// attached to them the way there is on `ItineraryItem.startsAt`.
@Model
final class Trip {
    @Attribute(.unique) var id: UUID
    var title: String
    var destination: String
    var countryCode: String
    var startDate: Date
    var endDate: Date
    var coverGradient: String
    var tripTypeRaw: String
    var createdBy: UUID
    var createdAt: Date
    var updatedAt: Date
    var updatedBy: UUID?

    init(
        id: UUID,
        title: String,
        destination: String,
        countryCode: String,
        startDate: Date,
        endDate: Date,
        coverGradient: String,
        tripTypeRaw: String,
        createdBy: UUID,
        createdAt: Date,
        updatedAt: Date,
        updatedBy: UUID?
    ) {
        self.id = id
        self.title = title
        self.destination = destination
        self.countryCode = countryCode
        self.startDate = startDate
        self.endDate = endDate
        self.coverGradient = coverGradient
        self.tripTypeRaw = tripTypeRaw
        self.createdBy = createdBy
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.updatedBy = updatedBy
    }

    var tripType: TripType {
        get { TripType(rawValue: tripTypeRaw) ?? .family }
        set { tripTypeRaw = newValue.rawValue }
    }
}

/// Explicit, since `@Model` doesn't synthesize this: lets Home use
/// `ForEach(trips)` and `.sheet(item:)` for the edit form directly off the
/// existing `id` rather than a second identity mechanism.
extension Trip: Identifiable {}

/// Wire shape for `trips`. `startDate`/`endDate` are `DayDate` (plain
/// `date` columns), everything else follows `JSONCoding`'s usual
/// snake_case + ISO8601 handling.
struct TripDTO: Codable, Sendable, Equatable {
    var id: UUID
    var title: String
    var destination: String
    var countryCode: String
    var startDate: DayDate
    var endDate: DayDate
    var coverGradient: String
    var tripType: String
    var createdBy: UUID
    var createdAt: Date
    var updatedAt: Date
    var updatedBy: UUID?
}

extension Trip {
    convenience init(dto: TripDTO) {
        self.init(
            id: dto.id,
            title: dto.title,
            destination: dto.destination,
            countryCode: dto.countryCode,
            startDate: dto.startDate.asDate(),
            endDate: dto.endDate.asDate(),
            coverGradient: dto.coverGradient,
            tripTypeRaw: dto.tripType,
            createdBy: dto.createdBy,
            createdAt: dto.createdAt,
            updatedAt: dto.updatedAt,
            updatedBy: dto.updatedBy
        )
    }

    func apply(_ dto: TripDTO) {
        title = dto.title
        destination = dto.destination
        countryCode = dto.countryCode
        startDate = dto.startDate.asDate()
        endDate = dto.endDate.asDate()
        coverGradient = dto.coverGradient
        tripTypeRaw = dto.tripType
        createdBy = dto.createdBy
        createdAt = dto.createdAt
        updatedAt = dto.updatedAt
        updatedBy = dto.updatedBy
    }

    func toDTO() -> TripDTO {
        TripDTO(
            id: id,
            title: title,
            destination: destination,
            countryCode: countryCode,
            startDate: DayDate.from(startDate),
            endDate: DayDate.from(endDate),
            coverGradient: coverGradient,
            tripType: tripTypeRaw,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            updatedBy: updatedBy
        )
    }
}
