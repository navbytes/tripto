import XCTest
@testable import Tripto

/// Home's Upcoming/Past bucketing (BUILD_PLAN.md §4.1), with explicit
/// boundary-day cases — the exact place off-by-one bugs hide. Uses a fixed
/// UTC calendar throughout (never `Calendar.current`) so the test result
/// doesn't depend on the machine running it.
final class DateBucketingTests: XCTestCase {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        DayDate(year: year, month: month, day: day).asDate(calendar: utc)
    }

    func testFutureTripIsUpcoming() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 8, 1), endDate: day(2026, 8, 5), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .upcoming)
    }

    func testTripThatEndedBeforeTodayIsPast() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 5, 1), endDate: day(2026, 5, 5), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .past)
    }

    func testTripSpanningTodayIsInProgress() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 1), endDate: day(2026, 7, 10), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .inProgress)
    }

    func testBoundaryTripStartingTodayIsInProgressNotUpcoming() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 8), endDate: day(2026, 7, 12), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .inProgress)
    }

    func testBoundaryTripEndingTodayIsStillInProgressNotPast() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 1), endDate: day(2026, 7, 8), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .inProgress, "BUILD_PLAN.md §4.1: Past = end_date < today, strictly")
    }

    func testBoundaryTripThatEndedYesterdayIsPast() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 1), endDate: day(2026, 7, 7), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .past)
    }

    func testSingleDayTripToday() {
        let bucket = TripDateBucketing.bucket(
            startDate: day(2026, 7, 8), endDate: day(2026, 7, 8), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(bucket, .inProgress)
    }

    func testDaysUntilStart() {
        let days = TripDateBucketing.daysUntilStart(
            startDate: day(2026, 7, 20), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(days, 12)
    }

    func testDaysUntilStartIsZeroOnStartDay() {
        let days = TripDateBucketing.daysUntilStart(
            startDate: day(2026, 7, 8), today: day(2026, 7, 8), calendar: utc
        )
        XCTAssertEqual(days, 0)
    }

    /// ACCEPTANCE.md "(c)": a 3-night stay (May 14 -> May 17) spans N+1 = 4
    /// calendar days.
    func testDurationInDaysIsInclusive() {
        let duration = TripDateBucketing.durationInDays(
            startDate: day(2026, 5, 14), endDate: day(2026, 5, 17), calendar: utc
        )
        XCTAssertEqual(duration, 4)
    }

    func testDurationInDaysForASingleDayTrip() {
        let duration = TripDateBucketing.durationInDays(
            startDate: day(2026, 5, 14), endDate: day(2026, 5, 14), calendar: utc
        )
        XCTAssertEqual(duration, 1)
    }
}
