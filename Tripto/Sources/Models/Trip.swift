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
    /// `trips.cover_image_path` (P8b, `.claude/company/ux-redesign/handoffs/
    /// P8-images-plan.md` D3) — see `Profile.avatarPath`'s doc comment for
    /// the path-not-URL/nullable/additive reasoning, identical here. `nil`
    /// means no photo — `coverGradient` above is the permanent fallback,
    /// never removed/replaced by adding this column.
    var coverImagePath: String?
    /// P8c (Pexels stock-photo covers, not yet written by any code path —
    /// this app only ever writes `nil` here today): photographer display
    /// name for the required "Photo by {name} on Pexels" attribution.
    /// Present here (read-only from this phase's own writes) so the render
    /// slot (`TripFormView`'s cover section) and the DTO/archive plumbing
    /// are already in place — P8c only has to start WRITING a value.
    var coverCreditName: String?
    /// P8c: the credit's required link target (a real external URL, unlike
    /// `coverImagePath` — see `TripDTO.coverCreditUrl`'s own doc comment for
    /// why it's spelled `Url`, not `URL`). Null iff `coverImagePath` was
    /// never sourced from Pexels.
    var coverCreditUrl: String?
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
        updatedBy: UUID?,
        coverImagePath: String? = nil,
        coverCreditName: String? = nil,
        coverCreditUrl: String? = nil
    ) {
        self.id = id
        self.title = title
        self.destination = destination
        self.countryCode = countryCode
        self.startDate = startDate
        self.endDate = endDate
        self.coverGradient = coverGradient
        self.coverImagePath = coverImagePath
        self.coverCreditName = coverCreditName
        self.coverCreditUrl = coverCreditUrl
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
    /// See `Trip.coverImagePath`'s doc comment; defaulted for the same
    /// "absent server column / plain memberwise init" reasons as
    /// `ProfileDTO.avatarPath`.
    var coverImagePath: String?
    /// See `Trip.coverCreditName`'s doc comment.
    var coverCreditName: String?
    /// See `Trip.coverCreditUrl`'s doc comment. Spelled `Url`, not `URL`:
    /// `JSONCoding`'s `.convertToSnakeCase`/`.convertFromSnakeCase` pair is
    /// NOT a true inverse for a trailing all-caps acronym — confirmed
    /// empirically, not assumed. `.convertToSnakeCase` on `coverCreditURL`
    /// correctly produces `cover_credit_url`, but `.convertFromSnakeCase` on
    /// `cover_credit_url` produces `coverCreditUrl` (lowercase `rl`), which
    /// then fails to match a `coverCreditURL` property/CodingKey at all —
    /// decodes as `nil` every time, silently. `coverCreditUrl` is the one
    /// spelling that round-trips both directions through the shared
    /// snake_case strategy; see `DTORoundTripTests` for the pinned proof.
    var coverCreditUrl: String?
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
            updatedBy: dto.updatedBy,
            coverImagePath: dto.coverImagePath,
            coverCreditName: dto.coverCreditName,
            coverCreditUrl: dto.coverCreditUrl
        )
    }

    func apply(_ dto: TripDTO) {
        title = dto.title
        destination = dto.destination
        countryCode = dto.countryCode
        startDate = dto.startDate.asDate()
        endDate = dto.endDate.asDate()
        coverGradient = dto.coverGradient
        coverImagePath = dto.coverImagePath
        coverCreditName = dto.coverCreditName
        coverCreditUrl = dto.coverCreditUrl
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
            coverImagePath: coverImagePath,
            coverCreditName: coverCreditName,
            coverCreditUrl: coverCreditUrl,
            tripType: tripTypeRaw,
            createdBy: createdBy,
            createdAt: createdAt,
            updatedAt: updatedAt,
            updatedBy: updatedBy
        )
    }
}
