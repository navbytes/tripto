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

    func testOverallValidityRequiresBothRules() {
        let start = Date()
        let end = start.addingTimeInterval(86400)

        XCTAssertTrue(TripFormValidation.isValid(title: "Lisbon", startDate: start, endDate: end))
        XCTAssertFalse(TripFormValidation.isValid(title: "", startDate: start, endDate: end))
        XCTAssertFalse(TripFormValidation.isValid(title: "Lisbon", startDate: end, endDate: start))
    }
}
