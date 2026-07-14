import XCTest
@testable import Tripto

/// Pure math backing `BoardingPassCard` (docs/UX_REDESIGN_ROADMAP.md Phase
/// 1) — duration, cross-midnight day offset, and the GMT-offset label,
/// deterministic and UI-free per `PassEffects.swift`'s own precedent.
final class BoardingPassMathTests: XCTestCase {
    private func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return utc.date(from: components)!
    }

    // MARK: - Duration formatting

    /// The design mockup's own HKG->BKK flight (design/ux-redesign-2026-07/
    /// tripto-redesign.html): 12:20 GMT+8 -> 14:00 GMT+7 is 2h40m of real
    /// elapsed time, not the 1h40m a naive wall-clock subtraction would give.
    func testDurationTextMatchesTheMockupsFlight() {
        let departure = utcInstant(2026, 7, 20, 4, 20) // 12:20 HKT
        let arrival = utcInstant(2026, 7, 20, 7, 0) // 14:00 ICT
        XCTAssertEqual(BoardingPassMath.durationText(from: departure, to: arrival), "2h 40m")
    }

    func testDurationTextDropsAZeroMinutesRemainder() {
        let departure = utcInstant(2026, 7, 20, 4, 0)
        let arrival = utcInstant(2026, 7, 20, 7, 0)
        XCTAssertEqual(BoardingPassMath.durationText(from: departure, to: arrival), "3h")
    }

    func testDurationTextUnderAnHourShowsMinutesOnly() {
        let departure = utcInstant(2026, 7, 20, 4, 0)
        let arrival = utcInstant(2026, 7, 20, 4, 45)
        XCTAssertEqual(BoardingPassMath.durationText(from: departure, to: arrival), "45m")
    }

    func testDurationTextNeverGoesNegativeForAnOutOfOrderInput() {
        let departure = utcInstant(2026, 7, 20, 7, 0)
        let arrival = utcInstant(2026, 7, 20, 4, 0)
        XCTAssertEqual(BoardingPassMath.durationText(from: departure, to: arrival), "0m")
    }

    // MARK: - Cross-midnight (+1d) arrival

    /// Eastbound red-eye: departs 23:30 local (UTC), arrives 06:00 local
    /// the next calendar day at UTC+5 — the common "+1d" case.
    func testDayBadgeShowsPlusOneDayWhenArrivalIsTheNextLocalDay() {
        let departureTz = TimeZone(identifier: "UTC")!
        let arrivalTz = TimeZone(identifier: "Asia/Karachi")! // UTC+5, no DST
        let departure = utcInstant(2026, 7, 20, 23, 30)
        let arrival = utcInstant(2026, 7, 21, 1, 0) // 06:00 the next day at UTC+5
        XCTAssertEqual(
            BoardingPassMath.dayBadgeText(departure: departure, departureTz: departureTz, arrival: arrival, arrivalTz: arrivalTz),
            "+1d"
        )
        XCTAssertEqual(
            BoardingPassMath.dayOffset(departure: departure, departureTz: departureTz, arrival: arrival, arrivalTz: arrivalTz), 1
        )
    }

    func testDayBadgeIsNilWhenArrivalIsTheSameLocalDay() {
        let tz = TimeZone(identifier: "UTC")!
        let departure = utcInstant(2026, 7, 20, 4, 20)
        let arrival = utcInstant(2026, 7, 20, 7, 0)
        XCTAssertNil(BoardingPassMath.dayBadgeText(departure: departure, departureTz: tz, arrival: arrival, arrivalTz: tz))
    }

    /// Westbound date-line crossing: a flight leaving Auckland (UTC+12) in
    /// the morning lands in Honolulu (UTC-10) still "the day before" by the
    /// local calendar — the rarer case where the arrival's local day reads
    /// *earlier* than departure's despite arrival being later in real time.
    func testDayBadgeShowsMinusOneDayForAWestboundDateLineCrossing() {
        let departureTz = TimeZone(identifier: "Pacific/Auckland")!
        let arrivalTz = TimeZone(identifier: "Pacific/Honolulu")!
        let departure = utcInstant(2026, 7, 21, 20, 0) // 08:00 the next day in Auckland (UTC+12)
        let arrival = utcInstant(2026, 7, 22, 5, 0) // 19:00 the day before in Honolulu (UTC-10)
        XCTAssertEqual(
            BoardingPassMath.dayBadgeText(departure: departure, departureTz: departureTz, arrival: arrival, arrivalTz: arrivalTz),
            "\u{2212}1d"
        )
    }

    // MARK: - GMT offset label

    func testGmtOffsetLabelFormatsWholeHourZones() {
        let hkg = TimeZone(identifier: "Asia/Hong_Kong")!
        XCTAssertEqual(BoardingPassMath.gmtOffsetLabel(for: hkg, at: utcInstant(2026, 7, 20, 0, 0)), "GMT+8")
    }

    func testGmtOffsetLabelFormatsHalfHourZones() {
        let kolkata = TimeZone(identifier: "Asia/Kolkata")!
        XCTAssertEqual(BoardingPassMath.gmtOffsetLabel(for: kolkata, at: utcInstant(2026, 7, 20, 0, 0)), "GMT+5:30")
    }

    func testGmtOffsetLabelFormatsNegativeOffsets() {
        let newYorkSummer = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(BoardingPassMath.gmtOffsetLabel(for: newYorkSummer, at: utcInstant(2026, 7, 20, 12, 0)), "GMT-4") // EDT
    }

    func testGmtOffsetLabelRendersPlainGMTAtZeroOffset() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(BoardingPassMath.gmtOffsetLabel(for: utc, at: utcInstant(2026, 7, 20, 0, 0)), "GMT")
    }
}

/// `ItineraryItem` -> `BoardingPassCard.Model` adapter (`BoardingPassContent`,
/// `TimelineModels.swift`) — the one place the "no ItineraryItem coupling
/// inside the card itself" contract is bridged.
final class BoardingPassContentTests: XCTestCase {
    private func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return utc.date(from: components)!
    }

    func testNonFlightCategoryProducesNoBoardingPass() {
        let hotel = TestFixtures.makeItineraryItem(category: .hotel, startsAt: utcInstant(2026, 5, 14, 15, 0))
        XCTAssertNil(BoardingPassContent.make(for: hotel))
    }

    /// Same-day landing (no zone shift): the footer is absent, matching
    /// `TZShiftChip.landingText`'s own contract.
    func testFooterTextIsAbsentWhenArrivalZoneMatchesDeparture() {
        var details = ItemDetails.empty
        details.fromIATA = "LIS"; details.toIATA = "OPO"; details.arrivalTz = "Europe/Lisbon"
        let flight = TestFixtures.makeItineraryItem(
            category: .flight, startsAt: utcInstant(2026, 6, 1, 8, 0), endsAt: utcInstant(2026, 6, 1, 9, 0),
            tz: "Europe/Lisbon", details: details
        )
        XCTAssertNil(BoardingPassContent.make(for: flight)?.footerText)
    }

    /// Zone-shifting landing: the footer reuses `TZShiftChip.landingText`'s
    /// own live output verbatim — this proves the reuse, not a hardcoded
    /// guess at its wording (do not reinvent it, per the roadmap).
    func testFooterTextIsPresentAndReusesTZShiftChipWordingWhenZonesDiffer() {
        var details = ItemDetails.empty
        details.fromIATA = "HKG"; details.toIATA = "BKK"; details.arrivalTz = "Asia/Bangkok"
        let flight = TestFixtures.makeItineraryItem(
            category: .flight,
            startsAt: utcInstant(2026, 7, 20, 4, 20), endsAt: utcInstant(2026, 7, 20, 7, 0),
            tz: "Asia/Hong_Kong", details: details
        )
        let model = BoardingPassContent.make(for: flight)
        XCTAssertEqual(model?.footerText, TZShiftChip.landingText(for: flight))
        XCTAssertNotNil(model?.footerText)
        XCTAssertEqual(model?.origin.code, "HKG")
        XCTAssertEqual(model?.destination.code, "BKK")
        XCTAssertEqual(model?.origin.timeZone.identifier, "Asia/Hong_Kong")
        XCTAssertEqual(model?.destination.timeZone.identifier, "Asia/Bangkok")
    }

    func testMissingAirportCodeFallsBackToEmDash() {
        let flight = TestFixtures.makeItineraryItem(category: .flight, startsAt: utcInstant(2026, 6, 1, 8, 0), tz: "UTC")
        let model = BoardingPassContent.make(for: flight)
        XCTAssertEqual(model?.origin.code, "\u{2014}")
        XCTAssertEqual(model?.destination.code, "\u{2014}")
    }

    func testCarrierLineFallsBackToItemTitleWhenAirlineAndFlightNoAreMissing() {
        let flight = TestFixtures.makeItineraryItem(
            category: .flight, title: "Mystery flight", startsAt: utcInstant(2026, 6, 1, 8, 0)
        )
        XCTAssertEqual(BoardingPassContent.make(for: flight)?.carrierLine, "Mystery flight")
    }

    func testCarrierLineCombinesAirlineAndFlightNumberWhenPresent() {
        var details = ItemDetails.empty
        details.airline = "Thai Airways"; details.flightNo = "TG639"
        let flight = TestFixtures.makeItineraryItem(category: .flight, startsAt: utcInstant(2026, 6, 1, 8, 0), details: details)
        XCTAssertEqual(BoardingPassContent.make(for: flight)?.carrierLine, "Thai Airways TG639")
    }
}
