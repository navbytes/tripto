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

    /// Kathmandu (UTC+5:45) — the rarer 45-minute offset, alongside
    /// Kolkata's 30-minute one above; this user's real trips include both
    /// India and Nepal, and a naive half-hour-only formatter would
    /// mis-render this one.
    func testGmtOffsetLabelFormatsA45MinuteZone() {
        let kathmandu = TimeZone(identifier: "Asia/Kathmandu")!
        XCTAssertEqual(BoardingPassMath.gmtOffsetLabel(for: kathmandu, at: utcInstant(2026, 7, 20, 0, 0)), "GMT+5:45")
    }

    /// A negative offset that *also* isn't a whole hour — an untested
    /// combination: the existing negative case above (New York) is
    /// whole-hour, and the existing fractional cases (Kolkata/Kathmandu) are
    /// positive. Marquesas has no DST, so this is deterministic on any date.
    func testGmtOffsetLabelFormatsANegativeNonHourZone() {
        let marquesas = TimeZone(identifier: "Pacific/Marquesas")!
        XCTAssertEqual(BoardingPassMath.gmtOffsetLabel(for: marquesas, at: utcInstant(2026, 7, 20, 0, 0)), "GMT-9:30")
    }

    // MARK: - Duration edge cases

    /// `durationText` must read as true elapsed time, not a wall-clock
    /// subtraction — 01:00 EST to 04:00 EDT on 2026-03-08 (America/New_York's
    /// own spring-forward instant) looks like "3h" on a clock face, but only
    /// 2 real hours pass. The function only ever sees two raw `Date`
    /// instants (no `TimeZone` parameter), so this also documents that
    /// invariant for anyone tempted to reintroduce a `Calendar`-based
    /// wall-clock computation.
    func testDurationTextReflectsTrueElapsedTimeAcrossASpringForwardDstTransition() {
        let departure = utcInstant(2026, 3, 8, 6, 0) // 01:00 EST
        let arrival = utcInstant(2026, 3, 8, 8, 0) // 04:00 EDT, after the 2am jump
        XCTAssertEqual(BoardingPassMath.durationText(from: departure, to: arrival), "2h")
    }

    func testDurationTextIsZeroMinutesWhenArrivalExactlyEqualsDeparture() {
        let instant = utcInstant(2026, 7, 20, 4, 0)
        XCTAssertEqual(BoardingPassMath.durationText(from: instant, to: instant), "0m")
    }

    // MARK: - Bad data / multi-day magnitude

    /// Bad data (e.g. a corrupt import): `endsAt` earlier than `startsAt`.
    /// `dayOffset`/`dayBadgeText` are plain calendar-day subtraction with no
    /// ordering assumption baked in, so a reversed pair must still return a
    /// deterministic value instead of crashing — `durationText`'s own clamp
    /// (`testDurationTextNeverGoesNegativeForAnOutOfOrderInput` above)
    /// already covers the duration half of this same bad-data case.
    func testDayOffsetAndBadgeHandleArrivalBeforeDepartureWithoutCrashing() {
        let tz = TimeZone(identifier: "UTC")!
        let departure = utcInstant(2026, 7, 20, 10, 0)
        let arrival = utcInstant(2026, 7, 19, 22, 0) // 12 hours *before* departure
        XCTAssertEqual(BoardingPassMath.dayOffset(departure: departure, departureTz: tz, arrival: arrival, arrivalTz: tz), -1)
        XCTAssertEqual(
            BoardingPassMath.dayBadgeText(departure: departure, departureTz: tz, arrival: arrival, arrivalTz: tz),
            "\u{2212}1d"
        )
    }

    /// The ±1d cases above only ever exercise the offset's *sign* — this
    /// pins its magnitude past 1, which is also what gives
    /// `BoardingPassAccessibilityPartsTests` below something real to
    /// pluralize.
    func testDayBadgeShowsPlusTwoDaysForAMultiDayLaterArrival() {
        let tz = TimeZone(identifier: "UTC")!
        let departure = utcInstant(2026, 7, 20, 23, 0)
        let arrival = utcInstant(2026, 7, 22, 2, 0) // 2 calendar days later
        XCTAssertEqual(BoardingPassMath.dayBadgeText(departure: departure, departureTz: tz, arrival: arrival, arrivalTz: tz), "+2d")
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

    /// Transport reuses `details.arrivalTz` for its own drop-off zone
    /// (`TransportCategoryTests`) — a guard that ever loosened from an exact
    /// `category == .flight` check to "has an arrivalTz" would wrongly hand
    /// a transport row a boarding pass. `testNonFlightCategoryProducesNoBoardingPass`
    /// above covers a category with no arrivalTz at all (hotel); this pins
    /// the sharper, easier-to-regress-into case.
    func testTransportCategoryProducesNoBoardingPassEvenWithADropoffZoneSet() {
        var details = ItemDetails.empty
        details.provider = "Hertz"; details.dropoffLocation = "Boston Logan"; details.arrivalTz = "America/New_York"
        let rentalCar = TestFixtures.makeItineraryItem(
            category: .transport, startsAt: utcInstant(2026, 6, 1, 14, 0), endsAt: utcInstant(2026, 6, 1, 16, 0),
            tz: "America/Los_Angeles", details: details
        )
        XCTAssertNil(BoardingPassContent.make(for: rentalCar))
    }
}

/// `BoardingPassCard.accessibilityParts(for:)` — the one VoiceOver sentence
/// builder behind both the card's own label and `TimelineCardRow.a11yLabel`
/// (docs/UX_REDESIGN_ROADMAP.md Phase 1's AX bullet: "one coherent sentence
/// per pass"). Previously untested; this pins its one real branch (day-note
/// pluralization) that the visual "+Nd" badge doesn't share, since the badge
/// never spells out "day(s)".
final class BoardingPassAccessibilityPartsTests: XCTestCase {
    private func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return utc.date(from: components)!
    }

    /// A plain `offset == 1 ? "" : "s"` slip (dropped or inverted) only ever
    /// surfaces past the first day — `dayBadgeText`'s own tests only reach
    /// magnitude 1, so this is the case that would actually catch it.
    func testAccessibilityPartsPluralizesADayCountGreaterThanOne() {
        let utc = TimeZone(identifier: "UTC")!
        let model = BoardingPassCard.Model(
            carrierLine: "Test Air TA1",
            origin: .init(code: "AAA", name: nil, date: utcInstant(2026, 7, 20, 23, 0), timeZone: utc),
            destination: .init(code: "BBB", name: nil, date: utcInstant(2026, 7, 22, 2, 0), timeZone: utc),
            footerText: nil
        )
        let parts = BoardingPassCard.accessibilityParts(for: model)
        XCTAssertTrue(parts[2].hasSuffix("2 days later"), parts[2])
    }
}
