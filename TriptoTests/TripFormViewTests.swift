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

    // MARK: - UX audit finding 1: CTA-guidance precedence (save error ->
    // blank title -> unacceptable country), including the CTA-slot fix that
    // surfaces an unacceptable country code even off-screen.

    func testCTAGuidancePrefersSaveErrorOverEverythingElse() {
        let guidance = TripFormView.ctaGuidance(
            saveError: "Couldn\u{2019}t save the trip. Try again.", title: "", countryCode: "PO", isEditing: false
        )
        XCTAssertEqual(guidance?.message, "Couldn\u{2019}t save the trip. Try again.")
        XCTAssertEqual(guidance?.isError, true)
    }

    func testCTAGuidanceFallsBackToBlankTitleWhenNoSaveError() {
        let guidance = TripFormView.ctaGuidance(saveError: nil, title: "  ", countryCode: "", isEditing: false)
        XCTAssertEqual(guidance?.message, "Enter a trip name to create the trip.")
        XCTAssertEqual(guidance?.isError, false)
    }

    func testCTAGuidanceSurfacesUnacceptableCountryWhenTitleIsValid() {
        let guidance = TripFormView.ctaGuidance(saveError: nil, title: "Lisbon", countryCode: "PO", isEditing: true)
        XCTAssertEqual(
            guidance?.message,
            "This trip\u{2019}s saved country isn\u{2019}t recognized. Tap Country and pick one \u{2014} or " +
                "choose \u{201C}No country\u{201D} \u{2014} to save changes."
        )
        XCTAssertEqual(guidance?.isError, true)
    }

    func testCTAGuidanceNilWhenEverythingIsAcceptable() {
        XCTAssertNil(TripFormView.ctaGuidance(saveError: nil, title: "Lisbon", countryCode: "PT", isEditing: false))
        XCTAssertNil(TripFormView.ctaGuidance(saveError: nil, title: "Lisbon", countryCode: "", isEditing: false))
    }

    func testCTAGuidancePrefersSaveErrorOverUnacceptableCountryWhenTitleIsValid() {
        let guidance = TripFormView.ctaGuidance(
            saveError: "Couldn\u{2019}t save the trip. Try again.", title: "Lisbon", countryCode: "PO", isEditing: true
        )
        XCTAssertEqual(guidance?.message, "Couldn\u{2019}t save the trip. Try again.")
        XCTAssertEqual(guidance?.isError, true)
    }

    // MARK: - Picker empty-results state: `countries(matching:)` must return
    // nothing for a city name or a misspelled country, not a spurious match.

    func testCountriesMatchingReturnsEmptyForCityNameOrTypo() {
        XCTAssertTrue(TripFormValidation.countries(matching: "Lisbon").isEmpty)
        XCTAssertTrue(TripFormValidation.countries(matching: "Protugal").isEmpty)
    }
}
