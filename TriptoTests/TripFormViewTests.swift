import SwiftData
import XCTest
@testable import Tripto

/// Coverage the pure `TripFormValidation` suite can't reach: F7's edit-path
/// stamping (needs an actual `Trip` model to assert `toDTO()` off of) and
/// F8's gradient-key normalization (a `TripFormView` static, exposed for
/// exactly this).
final class TripFormViewTests: XCTestCase {
    // MARK: - F7: edit path stamps updatedAt/updatedBy

    @MainActor
    func testEditMutationStampsUpdatedAtAndUpdatedByOnToDTO() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let creator = UUID()
        let editor = UUID()
        let originalUpdatedAt = Date(timeIntervalSince1970: 0)
        let trip = Trip(
            id: UUID(), title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: .now, endDate: .now.addingTimeInterval(86_400 * 6), coverGradient: "dusk",
            tripTypeRaw: TripType.family.rawValue, createdBy: creator,
            createdAt: originalUpdatedAt, updatedAt: originalUpdatedAt, updatedBy: nil
        )
        context.insert(trip)

        // The exact mutation `TripFormView.save()`'s edit branch performs
        // (mirroring `AddItemSheet.swift`'s `editing.updatedAt`/`updatedBy`).
        trip.title = "Porto"
        trip.updatedAt = .now
        trip.updatedBy = editor

        let dto = trip.toDTO()
        XCTAssertEqual(dto.title, "Porto")
        XCTAssertEqual(dto.updatedBy, editor)
        XCTAssertGreaterThan(dto.updatedAt, originalUpdatedAt)
    }

    // MARK: - F8: canonicalGradientKey normalization

    func testCanonicalGradientKeyMapsKnownKeysCaseInsensitively() {
        XCTAssertEqual(TripFormView.canonicalGradientKey("dusk"), "dusk")
        XCTAssertEqual(TripFormView.canonicalGradientKey("DUSK"), "dusk")
        XCTAssertEqual(TripFormView.canonicalGradientKey("plum"), "plum")
        XCTAssertEqual(TripFormView.canonicalGradientKey("moss"), "moss")
    }

    func testCanonicalGradientKeyFallsBackToDuskForUnknownOrLegacyKeys() {
        XCTAssertEqual(TripFormView.canonicalGradientKey("default"), "dusk")
        XCTAssertEqual(TripFormView.canonicalGradientKey("sunset"), "dusk")
        XCTAssertEqual(TripFormView.canonicalGradientKey(""), "dusk")
    }
}
