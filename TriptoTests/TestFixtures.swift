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
}
