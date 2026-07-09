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

    // MARK: - UX audit finding 6: isCoverGradientChanged compares by what a
    // key canonicalizes to, not the raw stored string.

    func testIsCoverGradientChangedFalseForLegacyDefaultKeyMatchingDusk() {
        // The finding's exact repro: a trip stored as "default" renders
        // Dusk-lit, so tapping the already-lit Dusk swatch (which writes
        // literal "dusk") shouldn't register as a change.
        XCTAssertFalse(TripFormView.isCoverGradientChanged(current: "dusk", initial: "default"))
    }

    func testIsCoverGradientChangedTrueForGenuinelyDifferentGradients() {
        XCTAssertTrue(TripFormView.isCoverGradientChanged(current: "plum", initial: "default"))
    }

    func testIsCoverGradientChangedFalseWhenKeysAreIdentical() {
        XCTAssertFalse(TripFormView.isCoverGradientChanged(current: "dusk", initial: "dusk"))
    }

    func testIsCoverGradientChangedFalseForCaseInsensitiveMatch() {
        XCTAssertFalse(TripFormView.isCoverGradientChanged(current: "moss", initial: "MOSS"))
    }

    func testIsCoverGradientChangedFalseForTwoDistinctUnknownLegacyKeys() {
        // Accepted edge (documented on the helper): two different unknown
        // legacy keys both canonicalize to "dusk", so this also reads as
        // clean — consistent with the swatch already rendering as selected.
        XCTAssertFalse(TripFormView.isCoverGradientChanged(current: "dusk", initial: "sunset"))
    }

    // MARK: - UX audit finding 1: CTA-guidance precedence (save error ->
    // blank title -> unacceptable country), including the CTA-slot fix that
    // surfaces an unacceptable country code even off-screen.

    func testCTAGuidancePrefersSaveErrorOverEverythingElse() {
        let guidance = TripFormView.ctaGuidance(
            saveError: "Couldn\u{2019}t save the trip. Try again.", title: "", countryCode: "PO", isEditing: false,
            isSignedOutOnCreate: false
        )
        XCTAssertEqual(guidance?.message, "Couldn\u{2019}t save the trip. Try again.")
        XCTAssertEqual(guidance?.isError, true)
    }

    func testCTAGuidanceFallsBackToBlankTitleWhenNoSaveError() {
        let guidance = TripFormView.ctaGuidance(
            saveError: nil, title: "  ", countryCode: "", isEditing: false, isSignedOutOnCreate: false
        )
        XCTAssertEqual(guidance?.message, "Enter a trip name to create the trip.")
        XCTAssertEqual(guidance?.isError, false)
    }

    func testCTAGuidanceSurfacesUnacceptableCountryWhenTitleIsValid() {
        let guidance = TripFormView.ctaGuidance(
            saveError: nil, title: "Lisbon", countryCode: "PO", isEditing: true, isSignedOutOnCreate: false
        )
        XCTAssertEqual(
            guidance?.message,
            "This trip\u{2019}s saved country isn\u{2019}t recognized. Tap Country and pick one \u{2014} or " +
                "choose \u{201C}No country\u{201D} \u{2014} to save changes."
        )
        XCTAssertEqual(guidance?.isError, true)
    }

    func testCTAGuidanceNilWhenEverythingIsAcceptable() {
        XCTAssertNil(TripFormView.ctaGuidance(
            saveError: nil, title: "Lisbon", countryCode: "PT", isEditing: false, isSignedOutOnCreate: false
        ))
        XCTAssertNil(TripFormView.ctaGuidance(
            saveError: nil, title: "Lisbon", countryCode: "", isEditing: false, isSignedOutOnCreate: false
        ))
    }

    func testCTAGuidancePrefersSaveErrorOverUnacceptableCountryWhenTitleIsValid() {
        let guidance = TripFormView.ctaGuidance(
            saveError: "Couldn\u{2019}t save the trip. Try again.", title: "Lisbon", countryCode: "PO", isEditing: true,
            isSignedOutOnCreate: false
        )
        XCTAssertEqual(guidance?.message, "Couldn\u{2019}t save the trip. Try again.")
        XCTAssertEqual(guidance?.isError, true)
    }

    // MARK: - UX audit cycle 2 finding 2: signed-out-on-create guidance takes
    // priority over everything else, including a save error and an otherwise
    // valid title/country — a signed-out create sheet can't be saved at all.

    func testCTAGuidancePrefersSignedOutOnCreateOverSaveErrorAndValidFields() {
        let guidance = TripFormView.ctaGuidance(
            saveError: "Couldn\u{2019}t save the trip. Try again.", title: "Lisbon", countryCode: "PT",
            isEditing: false, isSignedOutOnCreate: true
        )
        XCTAssertEqual(guidance?.message, "You\u{2019}re signed out. Sign back in to create a trip.")
        XCTAssertEqual(guidance?.isError, true)
    }

    // MARK: - Picker empty-results state: `countries(matching:)` must return
    // nothing for a city name or a misspelled country, not a spurious match.

    func testCountriesMatchingReturnsEmptyForCityNameOrTypo() {
        XCTAssertTrue(TripFormValidation.countries(matching: "Lisbon").isEmpty)
        XCTAssertTrue(TripFormValidation.countries(matching: "Protugal").isEmpty)
    }
}
