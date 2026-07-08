import XCTest
@testable import Tripto

final class TripFormValidationTests: XCTestCase {
    func testBlankOrWhitespaceOnlyTitleIsInvalid() {
        XCTAssertFalse(TripFormValidation.isTitleValid(""))
        XCTAssertFalse(TripFormValidation.isTitleValid("   "))
    }

    func testNonEmptyTitleIsValid() {
        XCTAssertTrue(TripFormValidation.isTitleValid("Lisbon"))
        XCTAssertTrue(TripFormValidation.isTitleValid("  Lisbon  "))
    }

    func testEndBeforeStartIsInvalid() {
        let start = Date()
        let end = start.addingTimeInterval(-86400)
        XCTAssertFalse(TripFormValidation.isDateRangeValid(startDate: start, endDate: end))
    }

    func testEndEqualToStartIsValid() {
        let date = Date()
        XCTAssertTrue(TripFormValidation.isDateRangeValid(startDate: date, endDate: date))
    }

    func testEndAfterStartIsValid() {
        let start = Date()
        let end = start.addingTimeInterval(86_400 * 6)
        XCTAssertTrue(TripFormValidation.isDateRangeValid(startDate: start, endDate: end))
    }

    func testCountryNameResolvesKnownCodes() {
        XCTAssertEqual(TripFormValidation.countryName(forCode: "PT"), "Portugal")
        XCTAssertEqual(TripFormValidation.countryName(forCode: "pt"), "Portugal")
    }

    func testCountryNameNilForUnassignedOrMalformedCodes() {
        XCTAssertNil(TripFormValidation.countryName(forCode: "PO")) // unassigned, not Portugal
        XCTAssertNil(TripFormValidation.countryName(forCode: "ZZ")) // reserved/unassigned
        XCTAssertNil(TripFormValidation.countryName(forCode: "P")) // 1 character
        XCTAssertNil(TripFormValidation.countryName(forCode: "PRT")) // 3 characters
        XCTAssertNil(TripFormValidation.countryName(forCode: "12")) // digits
    }

    func testIsCountryCodeAcceptable() {
        XCTAssertTrue(TripFormValidation.isCountryCodeAcceptable(""))
        XCTAssertTrue(TripFormValidation.isCountryCodeAcceptable("   "))
        XCTAssertTrue(TripFormValidation.isCountryCodeAcceptable("PT"))
        XCTAssertFalse(TripFormValidation.isCountryCodeAcceptable("PO"))
    }

    func testOverallValidityRequiresAllRules() {
        let start = Date()
        let end = start.addingTimeInterval(86400)

        XCTAssertTrue(TripFormValidation.isValid(title: "Lisbon", countryCode: "PT", startDate: start, endDate: end))
        XCTAssertTrue(TripFormValidation.isValid(title: "Lisbon", countryCode: "", startDate: start, endDate: end))
        XCTAssertFalse(TripFormValidation.isValid(title: "", countryCode: "PT", startDate: start, endDate: end))
        XCTAssertFalse(TripFormValidation.isValid(title: "Lisbon", countryCode: "PO", startDate: start, endDate: end))
        XCTAssertFalse(TripFormValidation.isValid(title: "Lisbon", countryCode: "PT", startDate: end, endDate: start))
    }
}
