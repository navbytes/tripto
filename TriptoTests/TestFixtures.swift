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
}
