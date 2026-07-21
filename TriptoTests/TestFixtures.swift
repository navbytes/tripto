import Foundation
@testable import Tripto

/// Shared fixture builders — kept tiny and boring on purpose, matching
/// SYNC_DESIGN.md's own "keep it boring" instruction.
enum TestFixtures {
    static func makeTripDTO(
        id: UUID,
        title: String = "Lisbon",
        startDate: DayDate = DayDate(year: 2026, month: 5, day: 14),
        endDate: DayDate = DayDate(year: 2026, month: 5, day: 20),
        createdBy: UUID = UUID()
    ) -> TripDTO {
        TripDTO(
            id: id,
            title: title,
            destination: "Lisbon, Portugal",
            countryCode: "PT",
            startDate: startDate,
            endDate: endDate,
            coverGradient: "dusk",
            tripType: "family",
            createdBy: createdBy,
            createdAt: .now,
            updatedAt: .now,
            updatedBy: nil
        )
    }

    /// E2's duplicate-trip tests build a `Trip` directly (not through DTO
    /// decode), same reasoning as `makeItineraryItem` below — pure model
    /// logic (`TripDuplication`), no network/SwiftData round trip involved.
    static func makeTrip(
        id: UUID = UUID(),
        title: String = "Lisbon",
        destination: String = "Lisbon, Portugal",
        countryCode: String = "PT",
        startDate: Date,
        endDate: Date,
        coverGradient: String = "dusk",
        tripType: TripType = .family,
        createdBy: UUID = UUID()
    ) -> Trip {
        Trip(
            id: id, title: title, destination: destination, countryCode: countryCode,
            startDate: startDate, endDate: endDate, coverGradient: coverGradient,
            tripTypeRaw: tripType.rawValue, createdBy: createdBy,
            createdAt: .now, updatedAt: .now, updatedBy: nil
        )
    }

    /// M2's timeline/tz-math tests build `ItineraryItem`s directly (not
    /// through DTO decode) since they exercise pure model logic
    /// (`ItineraryDayBucketing`, `ItineraryTimeZone`, `TZShiftChip`,
    /// `CalendarEventBuilder`) with no network/SwiftData round trip
    /// involved. Kept tiny and boring, matching `makeTripDTO` above.
    static func makeItineraryItem(
        id: UUID = UUID(),
        tripId: UUID = UUID(),
        category: ItemCategory = .activity,
        title: String = "Test item",
        startsAt: Date,
        endsAt: Date? = nil,
        tz: String = "UTC",
        locationName: String = "",
        confirmation: String? = nil,
        details: ItemDetails = .empty,
        status: ItemStatus = .confirmed,
        createdBy: UUID = UUID(),
        updatedAt: Date = .now,
        updatedBy: UUID? = nil
    ) -> ItineraryItem {
        let item = ItineraryItem(
            id: id, tripId: tripId, categoryRaw: category.rawValue, title: title,
            startsAt: startsAt, endsAt: endsAt, tz: tz, locationName: locationName,
            locationLat: nil, locationLng: nil, confirmation: confirmation, notes: nil,
            detailsJSON: "{}", statusRaw: status.rawValue, createdBy: createdBy,
            createdAt: .now, updatedAt: updatedAt, updatedBy: updatedBy
        )
        item.details = details
        return item
    }

    /// Release 1.2 (`.claude/company/release-1.2/PLAN.md` C1): kept as tiny
    /// and boring as the DTO builders above.
    static func makeItemAttachmentDTO(
        id: UUID = UUID(),
        tripId: UUID = UUID(),
        itemId: UUID = UUID(),
        fileName: String = "boarding-pass.pdf",
        contentType: AttachmentContentType = .pdf,
        byteSize: Int = 12_345,
        storagePath: String? = nil,
        createdBy: UUID? = UUID(),
        createdAt: Date = .now
    ) -> ItemAttachmentDTO {
        ItemAttachmentDTO(
            id: id, tripId: tripId, itemId: itemId, fileName: fileName,
            contentType: contentType.rawValue, byteSize: byteSize,
            storagePath: storagePath ?? AttachmentStorage.path(
                tripId: tripId, itemId: itemId, attachmentId: id, contentType: contentType
            ),
            createdBy: createdBy, createdAt: createdAt
        )
    }
}
