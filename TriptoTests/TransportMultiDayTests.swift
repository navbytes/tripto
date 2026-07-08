import XCTest
@testable import Tripto

/// Multi-day rental fix: a Transport item must represent a drop-off on a
/// *later date* than pickup (pick up Thursday, return Saturday). The original
/// form derived the drop-off from the pickup date plus a 0/1 "next day"
/// offset, so any rental longer than one night collapsed to same-day or
/// next-day. `AddItemSheet.transportInstants` composes start and end from two
/// independent dates.
final class TransportMultiDayTests: XCTestCase {
    private let lisbon = TimeZone(identifier: "Europe/Lisbon")!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }
    private func time(_ h: Int, _ min: Int) -> Date {
        Calendar.current.date(bySettingHour: h, minute: min, second: 0, of: Date())!
    }

    func testThreeDayRentalSpansMoreThanTwoDays() {
        let (start, end) = AddItemSheet.transportInstants(
            pickupDate: day(2026, 7, 8), pickupTime: time(10, 0), pickupTz: lisbon,
            dropoffDate: day(2026, 7, 11), dropoffTime: time(9, 0), dropoffTz: lisbon
        )
        // 8 Jul 10:00 → 11 Jul 09:00 in one zone = 71 hours.
        let hours = end.timeIntervalSince(start) / 3600
        XCTAssertEqual(hours, 71, accuracy: 1.0)
        XCTAssertGreaterThan(end.timeIntervalSince(start), 2 * 86_400,
                             "a multi-day rental must span past the old 0/1-day cap")
    }

    func testDropoffLandsOnTheDropoffDatePicked() {
        let (_, end) = AddItemSheet.transportInstants(
            pickupDate: day(2026, 7, 8), pickupTime: time(10, 0), pickupTz: lisbon,
            dropoffDate: day(2026, 7, 11), dropoffTime: time(9, 0), dropoffTz: lisbon
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = lisbon
        let comps = cal.dateComponents([.year, .month, .day], from: end)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 7)
        XCTAssertEqual(comps.day, 11, "drop-off must land on the chosen drop-off date, not pickup + offset")
    }

    func testSameDayTransferStillWorks() {
        let (start, end) = AddItemSheet.transportInstants(
            pickupDate: day(2026, 7, 8), pickupTime: time(9, 0), pickupTz: lisbon,
            dropoffDate: day(2026, 7, 8), dropoffTime: time(9, 45), dropoffTz: lisbon
        )
        XCTAssertEqual(end.timeIntervalSince(start) / 60, 45, accuracy: 1.0,
                       "a same-day airport transfer must still compose correctly")
    }

    func testZoneCrossingRentalUsesEachEndpointZone() {
        // Pick up in Lisbon 18:00, drop next day 10:00 in New York (−5h).
        let ny = TimeZone(identifier: "America/New_York")!
        let (start, end) = AddItemSheet.transportInstants(
            pickupDate: day(2026, 7, 8), pickupTime: time(18, 0), pickupTz: lisbon,
            dropoffDate: day(2026, 7, 9), dropoffTime: time(10, 0), dropoffTz: ny
        )
        XCTAssertGreaterThan(end, start)
        // 8 Jul 18:00 Lisbon (17:00Z) → 9 Jul 10:00 NY (14:00Z) = 21 hours.
        XCTAssertEqual(end.timeIntervalSince(start) / 3600, 21, accuracy: 1.0)
    }
}
