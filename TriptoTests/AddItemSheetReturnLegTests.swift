import XCTest
@testable import Tripto

/// "Save & add the return leg" (docs/UX_REDESIGN_ROADMAP.md P3.6):
/// `AddItemSheet.returnLegFields` is the pure transform behind the sticky
/// footer's secondary CTA — reverses the route, swaps the zones, advances
/// the date a day, and clears everything specific to one leg's own
/// schedule. Pure/static, mirroring `FlightTimeValidationTests`'/
/// `TransportMultiDayTests`' existing "call the static function directly,
/// no view involved" shape.
final class AddItemSheetReturnLegTests: XCTestCase {
    private let bangkok = TimeZone(identifier: "Asia/Bangkok")!
    private let hongKong = TimeZone(identifier: "Asia/Hong_Kong")!

    private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        return cal.date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testRouteIsReversed() {
        let next = AddItemSheet.returnLegFields(
            fromIATA: "BKK", toIATA: "HKG", departureZone: bangkok, arrivalZone: hongKong, flightDate: day(2026, 7, 26)
        )
        XCTAssertEqual(next.fromIATA, "HKG")
        XCTAssertEqual(next.toIATA, "BKK")
    }

    func testZonesAreSwapped() {
        let next = AddItemSheet.returnLegFields(
            fromIATA: "BKK", toIATA: "HKG", departureZone: bangkok, arrivalZone: hongKong, flightDate: day(2026, 7, 26)
        )
        XCTAssertEqual(next.departureZone, hongKong)
        XCTAssertEqual(next.arrivalZone, bangkok)
    }

    func testDateAdvancesByExactlyOneDay() {
        let outboundDate = day(2026, 7, 26)
        let next = AddItemSheet.returnLegFields(
            fromIATA: "BKK", toIATA: "HKG", departureZone: bangkok, arrivalZone: hongKong, flightDate: outboundDate
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        XCTAssertEqual(cal.dateComponents([.day], from: outboundDate, to: next.flightDate).day, 1)
    }

    /// The date math must use the *outbound* leg's own date, not "today" —
    /// pins that `flightDate` (the parameter), not some hidden `Date()`
    /// call, drives the +1d.
    func testDateAdvancesRelativeToTheOutboundLegsOwnDateNotToday() {
        let farFutureOutboundDate = day(2027, 1, 5)
        let next = AddItemSheet.returnLegFields(
            fromIATA: "BKK", toIATA: "HKG", departureZone: bangkok, arrivalZone: hongKong,
            flightDate: farFutureOutboundDate
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day], from: next.flightDate)
        XCTAssertEqual(comps.year, 2027)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 6)
    }

    func testSeatTerminalGateAndConfirmationAreCleared() {
        let next = AddItemSheet.returnLegFields(
            fromIATA: "BKK", toIATA: "HKG", departureZone: bangkok, arrivalZone: hongKong, flightDate: day(2026, 7, 26)
        )
        XCTAssertEqual(next.seat, "")
        XCTAssertEqual(next.terminal, "")
        XCTAssertEqual(next.gate, "")
        XCTAssertEqual(next.confirmation, "")
    }

    /// The "+1 day" override must reset to `nil` (auto-detect) for the new
    /// leg — carrying over the outbound leg's override would be stale once
    /// the times themselves have also been cleared/reset.
    func testArrivalDayOffsetOverrideResetsToAutoDetect() {
        let next = AddItemSheet.returnLegFields(
            fromIATA: "BKK", toIATA: "HKG", departureZone: bangkok, arrivalZone: hongKong, flightDate: day(2026, 7, 26)
        )
        XCTAssertNil(next.arrivalDayOffsetOverride)
    }

    /// `departsTime`/`arrivesTime` reset to the exact same "blank new
    /// flight" defaults `AddItemSheet.init()` uses (`Date()` / `now + 2h`) —
    /// not carried over from the outbound leg, which flies on a different
    /// day. Only the relationship between the two is meaningfully testable
    /// (both are `Date()`-derived at call time).
    func testTimesResetToFreshDefaultsWithArrivesAfterDeparts() {
        let before = Date()
        let next = AddItemSheet.returnLegFields(
            fromIATA: "BKK", toIATA: "HKG", departureZone: bangkok, arrivalZone: hongKong, flightDate: day(2026, 7, 26)
        )
        XCTAssertGreaterThanOrEqual(next.departsTime, before)
        XCTAssertEqual(next.arrivesTime.timeIntervalSince(next.departsTime), 2 * 3600, accuracy: 1.0)
    }

    /// A 31-day month rolling into the next — pins that the "+1 day" goes
    /// through real `Calendar` arithmetic (`Calendar.date(byAdding:)`), not
    /// some naive manual day-increment that would silently overflow a
    /// month's actual length.
    func testDateAdvancesAcrossAMonthBoundary() {
        let next = AddItemSheet.returnLegFields(
            fromIATA: "BKK", toIATA: "HKG", departureZone: bangkok, arrivalZone: hongKong, flightDate: day(2026, 1, 31)
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day], from: next.flightDate)
        XCTAssertEqual(comps.year, 2026)
        XCTAssertEqual(comps.month, 2)
        XCTAssertEqual(comps.day, 1)
    }

    /// December 31 rolling into January 1 of the *next* year — the same
    /// "+1 day" must also roll the year component, not wrap the month back
    /// to 1 while leaving the year untouched.
    func testDateAdvancesAcrossAYearBoundary() {
        let next = AddItemSheet.returnLegFields(
            fromIATA: "BKK", toIATA: "HKG", departureZone: bangkok, arrivalZone: hongKong, flightDate: day(2026, 12, 31)
        )
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let comps = cal.dateComponents([.year, .month, .day], from: next.flightDate)
        XCTAssertEqual(comps.year, 2027)
        XCTAssertEqual(comps.month, 1)
        XCTAssertEqual(comps.day, 1)
    }
}

/// Fix-round D1 (data loss): leg 2 is a *different* `ItineraryItem`, so its
/// assignee reconciliation must start from an empty baseline, not leg 1's
/// already-applied one — `saveAndAddReturnLeg()` resets
/// `originalAssigneeProfileIds = []` right after leg 1's save to guarantee
/// that. Exercises the same pure `AddItemSheet.assigneeReconciliation`
/// `reconcileAssignees` itself calls, so this pins the production diff
/// logic directly rather than re-deriving it.
final class AddItemSheetAssigneeReconciliationTests: XCTestCase {
    /// The regression itself: without the D1 reset, leg 2 would diff the
    /// still-selected people against the *same* set `reconcileAssignees`
    /// already recorded as "applied" for leg 1 — `toAdd` comes back empty,
    /// silently persisting zero `ItemAssignee` rows for leg 2's brand-new
    /// item even though the UI still shows everyone selected.
    func testUnresetOriginalAfterLeg1SaveWouldDropAllAssigneesForLeg2() {
        let grandma = UUID()
        let meera = UUID()
        let selectedForBothLegs: Set<UUID> = [grandma, meera]
        // Mirrors what `reconcileAssignees` leaves `originalAssigneeProfileIds`
        // as after leg 1's save: equal to whatever was selected.
        let staleOriginalFromLeg1 = selectedForBothLegs

        let (toAdd, _) = AddItemSheet.assigneeReconciliation(
            selected: selectedForBothLegs, original: staleOriginalFromLeg1
        )
        XCTAssertTrue(toAdd.isEmpty, "documents the bug: an un-reset baseline hides every assignee from leg 2")
    }

    /// The fix: resetting `original` to `[]` between the two saves (same
    /// people still selected) makes leg 2's diff see everyone as new —
    /// exactly the "leg 2 persists the same assignee set" the CTO asked for.
    func testResetOriginalToEmptyAfterLeg1SaveAddsEveryAssigneeForLeg2() {
        let grandma = UUID()
        let meera = UUID()
        let selectedForBothLegs: Set<UUID> = [grandma, meera]

        let (toAdd, toRemove) = AddItemSheet.assigneeReconciliation(
            selected: selectedForBothLegs, original: []
        )
        XCTAssertEqual(toAdd, selectedForBothLegs, "leg 2 must persist the exact same assignees leg 1 had")
        XCTAssertTrue(toRemove.isEmpty)
    }
}
