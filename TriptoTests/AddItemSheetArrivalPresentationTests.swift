import XCTest
@testable import Tripto

/// P7e (round-2 re-audit item 1): the "Arrival date"/"Arrives" rows' unset-
/// vs-set presentation is gated on `AddItemSheet.hasSetArrival`
/// (`arrivesTime != nil`) — a `@State`-backed computed property with no pure
/// entry point a test can drive without standing up a live view, so this
/// doesn't force one (per the brief: "don't force a view test otherwise").
/// `defaultArrivalTime` is the one piece of new logic this fix actually adds
/// as a pure `static func` (mirroring `flightInstants`/`returnLegFields`'s
/// own "pure function computes, the view applies it" split): both
/// `arrivesTimeBinding`'s display fallback and `arrivalPlaceholderRow`'s
/// reveal-on-first-tap action read it, so this pins that revealing arrival
/// for the first time commits exactly the value the picker was already
/// showing beforehand — no jump the instant the placeholder is tapped.
final class AddItemSheetArrivalPresentationTests: XCTestCase {
    func testDefaultArrivalTimeIsTwoHoursAfterDeparture() {
        let departs = Date(timeIntervalSince1970: 1_752_000_000)
        let revealed = AddItemSheet.defaultArrivalTime(departsTime: departs)
        XCTAssertEqual(revealed.timeIntervalSince(departs), 2 * 3600, accuracy: 0.01)
    }

    /// Same math regardless of which calendar day/hour `departsTime` lands
    /// on — a late-night departure rolling past midnight is still exactly
    /// two hours later, not clamped or wrapped.
    func testDefaultArrivalTimeCrossesMidnightCorrectly() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let lateDeparture = cal.date(from: DateComponents(year: 2026, month: 7, day: 8, hour: 23, minute: 30))!
        let revealed = AddItemSheet.defaultArrivalTime(departsTime: lateDeparture)
        let comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: revealed)
        XCTAssertEqual(comps.day, 9)
        XCTAssertEqual(comps.hour, 1)
        XCTAssertEqual(comps.minute, 30)
    }
}
