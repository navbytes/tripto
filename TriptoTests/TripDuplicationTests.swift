import XCTest
@testable import Tripto

/// E2 (docs/BACKLOG.md §E2 "Duplicate trip") — `TripDuplication` is
/// Foundation-only (see its own doc comment), so every rule here (rebase
/// math, the details-key strip allowlist, packing reset, suggested-item
/// exclusion) is directly testable with no `ModelContainer` involved.
final class TripDuplicationTests: XCTestCase {
    /// Deliberately UTC, not `.current` — same "no hidden device time-zone
    /// dependency" discipline `TripDateBucketing`/`ItineraryTimeZone`'s own
    /// tests already follow.
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - dayDelta

    func testDayDeltaComputesWholeCalendarDaysBetweenTwoTripStarts() {
        let oldStart = utc.date(from: DateComponents(year: 2026, month: 5, day: 14))!
        let newStart = utc.date(from: DateComponents(year: 2027, month: 6, day: 5))!
        XCTAssertEqual(TripDuplication.dayDelta(from: oldStart, to: newStart, calendar: utc), 387)
    }

    func testDayDeltaIsNegativeWhenNewStartIsEarlier() {
        let oldStart = utc.date(from: DateComponents(year: 2026, month: 5, day: 14))!
        let newStart = utc.date(from: DateComponents(year: 2026, month: 5, day: 10))!
        XCTAssertEqual(TripDuplication.dayDelta(from: oldStart, to: newStart, calendar: utc), -4)
    }

    // MARK: - rebase (DST-safe wall-clock preservation)

    func testRebaseWithZeroDeltaReturnsTheSameInstant() {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        XCTAssertEqual(TripDuplication.rebase(date, byDays: 0, in: TimeZone(identifier: "UTC")!), date)
    }

    /// The brief's exact scenario: an item at 14:30 Europe/Lisbon rebased
    /// across a DST change stays 14:30 local; the UTC instant shifts
    /// accordingly. 2026-03-01 14:30 Lisbon (WET, UTC+0) shifted +60 days
    /// lands on 2026-04-30 (WEST, UTC+1) — Europe/Lisbon's spring-forward
    /// (last Sunday of March) always falls inside that window, so the two
    /// offsets are guaranteed to differ (verified: 2026's transition is
    /// March 29).
    func testRebasePreservesWallClockTimeAcrossADSTBoundary() {
        let lisbon = TimeZone(identifier: "Europe/Lisbon")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = lisbon

        let before = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1, hour: 14, minute: 30))!
        let after = TripDuplication.rebase(before, byDays: 60, in: lisbon)

        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: after)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 4)
        XCTAssertEqual(components.day, 30)
        XCTAssertEqual(components.hour, 14)
        XCTAssertEqual(components.minute, 30)

        // Proves this is genuinely DST-aware, not a naive 60*86_400s add:
        // the UTC offset shifted (WET -> WEST) partway through, so the
        // instant does not land exactly 60*24h later.
        let naiveShift = before.addingTimeInterval(60 * 86_400)
        XCTAssertNotEqual(after, naiveShift)
    }

    // MARK: - Prefill (title/destination/country/type/cover copied, duration preserved)

    func testPrefillTitleIsSuffixedCopyAndCarriesDestinationCountryTypeCover() {
        let source = TestFixtures.makeTrip(
            title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: utc.date(from: DateComponents(year: 2026, month: 5, day: 14))!,
            endDate: utc.date(from: DateComponents(year: 2026, month: 5, day: 20))!,
            coverGradient: "plum", tripType: .friends
        )
        let today = utc.date(from: DateComponents(year: 2027, month: 1, day: 10))!

        let seed = TripDuplication.prefill(for: source, today: today, calendar: utc)

        XCTAssertEqual(seed.title, "Lisbon copy")
        XCTAssertEqual(seed.destination, "Lisbon, Portugal")
        XCTAssertEqual(seed.countryCode, "PT")
        XCTAssertEqual(seed.tripType, .friends)
        XCTAssertEqual(seed.coverGradientKey, "plum")
    }

    func testPrefillStartsTodayAndPreservesTheSourceTripsDuration() {
        let source = TestFixtures.makeTrip(
            startDate: utc.date(from: DateComponents(year: 2026, month: 5, day: 14))!,
            endDate: utc.date(from: DateComponents(year: 2026, month: 5, day: 20))! // 7 days inclusive
        )
        let today = utc.date(from: DateComponents(year: 2027, month: 1, day: 10))!

        let seed = TripDuplication.prefill(for: source, today: today, calendar: utc)

        XCTAssertEqual(utc.startOfDay(for: seed.startDate), utc.startOfDay(for: today))
        XCTAssertEqual(
            TripDateBucketing.durationInDays(startDate: seed.startDate, endDate: seed.endDate, calendar: utc),
            source.durationInDays(calendar: utc)
        )
    }

    // MARK: - Strip rules (design brief's exact allowlist)

    func testStrippedDetailsDropsOnlyTheBookingSpecificsKeepsEverythingElse() {
        let details = ItemDetails(
            airline: "TAP", flightNo: "TP1234", fromIATA: "JFK", toIATA: "LIS",
            seat: "14A", terminal: "4", gate: "B12", arrivalTz: "Europe/Lisbon",
            room: "203", ticketRef: "TKT-1", partySize: 4, reservationName: "Silva",
            provider: "Hertz", dropoffLocation: "Lisbon Airport",
            address: "Rua Augusta 1", tags: ["nap"]
        )

        let stripped = TripDuplication.strippedDetails(details)

        XCTAssertNil(stripped.seat)
        XCTAssertNil(stripped.terminal)
        XCTAssertNil(stripped.gate)
        XCTAssertNil(stripped.ticketRef)
        XCTAssertNil(stripped.reservationName)

        XCTAssertEqual(stripped.airline, "TAP")
        XCTAssertEqual(stripped.flightNo, "TP1234")
        XCTAssertEqual(stripped.fromIATA, "JFK")
        XCTAssertEqual(stripped.toIATA, "LIS")
        XCTAssertEqual(stripped.arrivalTz, "Europe/Lisbon")
        XCTAssertEqual(stripped.room, "203")
        XCTAssertEqual(stripped.partySize, 4)
        XCTAssertEqual(stripped.provider, "Hertz")
        XCTAssertEqual(stripped.dropoffLocation, "Lisbon Airport")
        XCTAssertEqual(stripped.address, "Rua Augusta 1")
        XCTAssertEqual(stripped.tags, ["nap"])
    }

    // MARK: - cloneItem (confirmation/source/status/createdBy reset)

    func testCloneItemStripsConfirmationResetsProvenanceKeepsPlanFields() {
        let newTripId = UUID()
        let originalCreator = UUID()
        let duplicator = UUID()
        let source = TestFixtures.makeItineraryItem(
            category: .flight, title: "TAP TP1234", startsAt: .now, tz: "UTC",
            locationName: "JFK", confirmation: "ABC123",
            details: ItemDetails(seat: "14A", ticketRef: "TKT-1"),
            status: .confirmed, createdBy: originalCreator
        )
        source.source = .textImport

        let clone = TripDuplication.cloneItem(source, tripId: newTripId, dayDelta: 5, createdBy: duplicator, now: .now)

        XCTAssertNotEqual(clone.id, source.id)
        XCTAssertEqual(clone.tripId, newTripId)
        XCTAssertNil(clone.confirmation)
        XCTAssertEqual(clone.source, .manual)
        XCTAssertEqual(clone.status, .confirmed)
        XCTAssertEqual(clone.createdBy, duplicator)
        XCTAssertEqual(clone.title, "TAP TP1234")
        XCTAssertEqual(clone.locationName, "JFK")
        XCTAssertNil(clone.details.seat)
        XCTAssertNil(clone.details.ticketRef)
    }

    func testCloneItemRebasesStartsAtByTheDayDeltaInTheItemsOwnZone() {
        let lisbonId = "Europe/Lisbon"
        var lisbonCalendar = Calendar(identifier: .gregorian)
        lisbonCalendar.timeZone = TimeZone(identifier: lisbonId)!
        let startsAt = lisbonCalendar.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 8, minute: 20))!
        let source = TestFixtures.makeItineraryItem(startsAt: startsAt, tz: lisbonId)

        let clone = TripDuplication.cloneItem(source, tripId: UUID(), dayDelta: 3, createdBy: UUID(), now: .now)

        let components = lisbonCalendar.dateComponents([.month, .day, .hour, .minute], from: clone.startsAt)
        XCTAssertEqual(components.month, 5)
        XCTAssertEqual(components.day, 17)
        XCTAssertEqual(components.hour, 8)
        XCTAssertEqual(components.minute, 20)
    }

    /// A flight's `endsAt` rebases in its ARRIVAL zone (`details.arrivalTz`),
    /// not its departure `tz` — mirrors `ItineraryItem.endLocalDay`'s own
    /// rule, so a rebased red-eye keeps the correct landing-day wall clock
    /// even when departure and arrival are in different zones.
    func testCloneItemRebasesEndsAtInTheFlightsArrivalZone() {
        let nyTz = "America/New_York"
        let lisbonTz = "Europe/Lisbon"
        var nyCalendar = Calendar(identifier: .gregorian)
        nyCalendar.timeZone = TimeZone(identifier: nyTz)!
        var lisbonCalendar = Calendar(identifier: .gregorian)
        lisbonCalendar.timeZone = TimeZone(identifier: lisbonTz)!

        let startsAt = nyCalendar.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 22, minute: 0))!
        let endsAt = lisbonCalendar.date(from: DateComponents(year: 2026, month: 5, day: 15, hour: 10, minute: 30))!
        let source = TestFixtures.makeItineraryItem(
            category: .flight, startsAt: startsAt, endsAt: endsAt, tz: nyTz,
            details: ItemDetails(arrivalTz: lisbonTz)
        )

        let clone = TripDuplication.cloneItem(source, tripId: UUID(), dayDelta: 10, createdBy: UUID(), now: .now)

        let clonedEndComponents = lisbonCalendar.dateComponents([.month, .day, .hour, .minute], from: clone.endsAt!)
        XCTAssertEqual(clonedEndComponents.month, 5)
        XCTAssertEqual(clonedEndComponents.day, 25)
        XCTAssertEqual(clonedEndComponents.hour, 10)
        XCTAssertEqual(clonedEndComponents.minute, 30)
    }

    func testCloneItemLeavesEndsAtNilWhenSourceHasNone() {
        let source = TestFixtures.makeItineraryItem(startsAt: .now, endsAt: nil, tz: "UTC")
        let clone = TripDuplication.cloneItem(source, tripId: UUID(), dayDelta: 1, createdBy: UUID(), now: .now)
        XCTAssertNil(clone.endsAt)
    }

    // MARK: - Suggested-items exclusion

    func testConfirmedItemsKeepsOnlyConfirmedFromAMixedList() {
        let confirmed = TestFixtures.makeItineraryItem(startsAt: .now, tz: "UTC", status: .confirmed)
        let suggested = TestFixtures.makeItineraryItem(startsAt: .now, tz: "UTC", status: .suggested)
        XCTAssertEqual(TripDuplication.confirmedItems([confirmed, suggested]).map(\.id), [confirmed.id])
    }

    func testClonedItemsNeverIncludesASuggestedSourceItem() {
        let suggested = TestFixtures.makeItineraryItem(startsAt: .now, tz: "UTC", status: .suggested)
        let cloned = TripDuplication.clonedItems(
            from: [suggested], newTripId: UUID(), dayDelta: 0, createdBy: UUID(), now: .now
        )
        XCTAssertTrue(cloned.isEmpty)
    }

    // MARK: - Packing list cloning

    func testClonePackingItemResetsIsDoneAndDropsAssigneeKeepsLabelAndGroup() {
        let source = PackingItem(
            id: UUID(), tripId: UUID(), label: "Sunscreen", groupKeyRaw: PackingGroupKey.shared.rawValue,
            assigneeProfileId: UUID(), isDone: true, createdBy: UUID(),
            createdAt: .now, updatedAt: .now, updatedBy: nil
        )
        let newTripId = UUID()
        let duplicator = UUID()

        let clone = TripDuplication.clonePackingItem(source, tripId: newTripId, createdBy: duplicator, now: .now)

        XCTAssertNotEqual(clone.id, source.id)
        XCTAssertEqual(clone.tripId, newTripId)
        XCTAssertEqual(clone.label, "Sunscreen")
        XCTAssertEqual(clone.groupKeyRaw, PackingGroupKey.shared.rawValue)
        XCTAssertFalse(clone.isDone)
        XCTAssertNil(clone.assigneeProfileId)
        XCTAssertEqual(clone.createdBy, duplicator)
    }
}
