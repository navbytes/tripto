import XCTest
@testable import Tripto

/// `ShareSummary.text(for:)` feeds a `ShareLink` (`BookingDetailView.swift:1082`)
/// that leaves the app for Messages/third-party extensions — the CLAUDE.md
/// security model's rule ("never expose confirmation codes, notes, or
/// emails") applies here exactly as it does to the public share link and the
/// calendar handoff (`CalendarEventDraftTests.swift` already guards that
/// one; this is the same guard for this trust boundary). Covers every
/// `ItemCategory` since each switches on different `ItemDetails` fields — a
/// leak in one branch wouldn't be caught by testing only one.
///
/// `ItineraryItem`/`ItemDetails` has no dedicated email column; in practice
/// a stray email (a host's contact, a forwarded confirmation's reply-to)
/// would land inside free-text `notes`, so the sentinel below embeds an
/// email-shaped string in `notes` alongside a plain note phrase and asserts
/// neither ever surfaces.
///
/// Assertions are `contains`/`!contains` on the whole output, never exact
/// string equality: `formattedDay` (this file's own private day formatter)
/// is mid-relocation elsewhere with byte-identical output promised, and
/// this security-contract test must not couple to that unrelated refactor.
final class ShareSummaryTests: XCTestCase {
    private func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return utc.date(from: components)!
    }

    /// A category-tagged sentinel so a failure names exactly which
    /// category's branch leaked which field. F6 (security-auditor, LOW):
    /// `reservationName` (`ItemDetails`) is a PII-ish person name — planted
    /// on the food/activity fixtures below (the two categories sharing
    /// `ShareSummary`'s `case .activity, .food:` branch; food's own add-item
    /// form is the only surface that actually collects it today) alongside
    /// the existing three, same "assert it never appears" contract. A named
    /// struct, not a tuple — a 4th member would trip `large_tuple`.
    private struct Sentinel {
        let confirmation: String
        let note: String
        let email: String
        let reservationName: String
    }

    private func sentinels(for category: ItemCategory) -> Sentinel {
        let tag = category.rawValue.uppercased()
        return Sentinel(
            confirmation: "SENTINEL-CONF-\(tag)-482",
            note: "SENTINEL-NOTE-\(tag)-DO-NOT-SHARE",
            email: "sentinel-\(category.rawValue)@leak-test.example",
            reservationName: "SENTINEL-RESNAME-\(tag)"
        )
    }

    private func assertNoLeak(
        _ output: String, category: ItemCategory, _ sentinel: Sentinel,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(
            output.contains(sentinel.confirmation),
            "\(category) share summary must never include the confirmation code", file: file, line: line
        )
        XCTAssertFalse(
            output.contains(sentinel.note),
            "\(category) share summary must never include notes", file: file, line: line
        )
        XCTAssertFalse(
            output.contains(sentinel.email),
            "\(category) share summary must never include an email address", file: file, line: line
        )
        XCTAssertFalse(
            output.contains(sentinel.reservationName),
            "\(category) share summary must never include the reservation name", file: file, line: line
        )
    }

    func testFlightSummaryNeverLeaksConfirmationNotesOrEmail() {
        let sentinel = sentinels(for: .flight)
        var details = ItemDetails.empty
        details.airline = "TAP"; details.flightNo = "TP1234"
        details.fromIATA = "JFK"; details.toIATA = "LIS"
        let item = TestFixtures.makeItineraryItem(
            category: .flight, title: "Flight to Lisbon",
            startsAt: utcInstant(2026, 5, 14, 12, 20), tz: "America/New_York",
            confirmation: sentinel.confirmation, details: details
        )
        item.notes = "\(sentinel.note) \u{2014} reach us at \(sentinel.email)"

        let output = ShareSummary.text(for: item)

        assertNoLeak(output, category: .flight, sentinel)
        XCTAssertTrue(output.contains("TAP TP1234"), "flight name should be public")
        XCTAssertTrue(output.contains("JFK→LIS"), "route should be public")
        XCTAssertTrue(
            output.contains(ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)),
            "departure time should be public"
        )
        XCTAssertTrue(
            output.contains(ItineraryTimeZone.zoneLabel(for: item.primaryTz, at: item.startsAt)),
            "zone label should be public"
        )
    }

    func testHotelSummaryNeverLeaksConfirmationNotesOrEmail() {
        let sentinel = sentinels(for: .hotel)
        let item = TestFixtures.makeItineraryItem(
            category: .hotel, title: "Memmo Alfama",
            startsAt: utcInstant(2026, 5, 14, 15, 0), endsAt: utcInstant(2026, 5, 17, 11, 0), tz: "UTC",
            confirmation: sentinel.confirmation
        )
        item.notes = "\(sentinel.note) \u{2014} reach us at \(sentinel.email)"

        let output = ShareSummary.text(for: item)

        assertNoLeak(output, category: .hotel, sentinel)
        XCTAssertTrue(output.contains("Memmo Alfama"), "hotel title should be public")
        XCTAssertTrue(output.contains("3 nights"), "night count should be public")
        XCTAssertTrue(
            output.contains(ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)),
            "check-in time should be public"
        )
    }

    func testActivitySummaryNeverLeaksConfirmationNotesOrEmail() {
        let sentinel = sentinels(for: .activity)
        var details = ItemDetails.empty
        details.reservationName = sentinel.reservationName
        let item = TestFixtures.makeItineraryItem(
            category: .activity, title: "Belém Tower tour",
            startsAt: utcInstant(2026, 5, 15, 10, 0), tz: "Europe/Lisbon",
            locationName: "Belém, Lisbon",
            confirmation: sentinel.confirmation, details: details
        )
        item.notes = "\(sentinel.note) \u{2014} reach us at \(sentinel.email)"

        let output = ShareSummary.text(for: item)

        assertNoLeak(output, category: .activity, sentinel)
        XCTAssertTrue(output.contains("Belém Tower tour"), "activity title should be public")
        XCTAssertTrue(output.contains("Belém, Lisbon"), "location should be public")
        XCTAssertTrue(
            output.contains(ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)),
            "time should be public"
        )
    }

    func testFoodSummaryNeverLeaksConfirmationNotesOrEmail() {
        let sentinel = sentinels(for: .food)
        var details = ItemDetails.empty
        details.reservationName = sentinel.reservationName
        let item = TestFixtures.makeItineraryItem(
            category: .food, title: "Time Out Market",
            startsAt: utcInstant(2026, 5, 15, 19, 30), tz: "Europe/Lisbon",
            locationName: "Cais do Sodré, Lisbon",
            confirmation: sentinel.confirmation, details: details
        )
        item.notes = "\(sentinel.note) \u{2014} reach us at \(sentinel.email)"

        let output = ShareSummary.text(for: item)

        assertNoLeak(output, category: .food, sentinel)
        XCTAssertTrue(output.contains("Time Out Market"), "restaurant title should be public")
        XCTAssertTrue(output.contains("Cais do Sodré, Lisbon"), "location should be public")
        XCTAssertTrue(
            output.contains(ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)),
            "time should be public"
        )
    }

    func testTransportSummaryNeverLeaksConfirmationNotesOrEmail() {
        let sentinel = sentinels(for: .transport)
        var details = ItemDetails.empty
        details.provider = "Hertz"; details.dropoffLocation = "Manhattan Hotel"
        let item = TestFixtures.makeItineraryItem(
            category: .transport, title: "Rental car",
            startsAt: utcInstant(2026, 5, 16, 9, 0), tz: "America/New_York",
            locationName: "JFK Airport",
            confirmation: sentinel.confirmation, details: details
        )
        item.notes = "\(sentinel.note) \u{2014} reach us at \(sentinel.email)"

        let output = ShareSummary.text(for: item)

        assertNoLeak(output, category: .transport, sentinel)
        XCTAssertTrue(output.contains("Hertz"), "provider should be public")
        XCTAssertTrue(output.contains("JFK Airport→Manhattan Hotel"), "pickup/drop-off route should be public")
        XCTAssertTrue(
            output.contains(ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz)),
            "pickup time should be public"
        )
    }

    /// Day-label proof without pinning its exact text: two otherwise-identical
    /// items a week apart (same wall-clock time, UTC so no DST wrinkle) must
    /// produce different summaries — evidence the day label is genuinely
    /// embedded, without this test needing to know (or duplicate) the day
    /// formatter's own pattern/locale.
    func testDayLabelIsEmbeddedAndChangesWithTheCalendarDay() {
        let firstWeek = TestFixtures.makeItineraryItem(
            category: .activity, title: "Museum visit", startsAt: utcInstant(2026, 5, 14, 10, 0), tz: "UTC"
        )
        let secondWeek = TestFixtures.makeItineraryItem(
            category: .activity, title: "Museum visit", startsAt: utcInstant(2026, 5, 21, 10, 0), tz: "UTC"
        )

        XCTAssertNotEqual(
            ShareSummary.text(for: firstWeek), ShareSummary.text(for: secondWeek),
            "changing only the calendar day must change the summary"
        )
    }
}
