import XCTest
@testable import Tripto

/// `Features/Trip/ImportExtraction.swift` — pure, OS-version-free, so every
/// case here runs with no model, no network, no FoundationModels (R4 §6:
/// "do not attempt to unit-test actual model calls; do NOT invent a mock of
/// Apple's session" — nothing here does either).
final class ImportExtractionTests: XCTestCase {
    // MARK: - Routing matrix (availability × text-fits × consent-state)

    /// Full 2x2x2 matrix: on-device requires BOTH availability and fit;
    /// the consent dialog is required iff the route is `.remote` and
    /// consent hasn't been granted — on-device NEVER requires it,
    /// regardless of consent state (this is the pure proof `AIImportConsent`'s
    /// doc comment on `PasteImportSheet.submit()` points at).
    func testRoutingMatrix() {
        struct Case { let available: Bool; let fits: Bool; let consentGranted: Bool; let route: ImportRoute; let dialog: Bool }
        let cases: [Case] = [
            Case(available: true, fits: true, consentGranted: true, route: .onDevice, dialog: false),
            Case(available: true, fits: true, consentGranted: false, route: .onDevice, dialog: false),
            Case(available: true, fits: false, consentGranted: true, route: .remote, dialog: false),
            Case(available: true, fits: false, consentGranted: false, route: .remote, dialog: true),
            Case(available: false, fits: true, consentGranted: true, route: .remote, dialog: false),
            Case(available: false, fits: true, consentGranted: false, route: .remote, dialog: true),
            Case(available: false, fits: false, consentGranted: true, route: .remote, dialog: false),
            Case(available: false, fits: false, consentGranted: false, route: .remote, dialog: true),
        ]
        for testCase in cases {
            let route = ImportRouting.route(isOnDeviceAvailable: testCase.available, textFitsOnDevice: testCase.fits)
            XCTAssertEqual(
                route, testCase.route,
                "available=\(testCase.available) fits=\(testCase.fits) -> expected \(testCase.route)"
            )
            let dialog = ImportRouting.requiresConsentDialog(route: route, consentGranted: testCase.consentGranted)
            XCTAssertEqual(
                dialog, testCase.dialog,
                "route=\(route) consentGranted=\(testCase.consentGranted) -> expected dialog=\(testCase.dialog)"
            )
        }
    }

    // MARK: - Context-window pre-estimate

    func testTextAtOrUnderBudgetFits() {
        let text = String(repeating: "a", count: ImportContextBudget.maxPastedTextCharacters)
        XCTAssertTrue(ImportContextBudget.textFits(text))
        XCTAssertTrue(ImportContextBudget.textFits(""))
    }

    func testTextOverBudgetDoesNotFit() {
        let text = String(repeating: "a", count: ImportContextBudget.maxPastedTextCharacters + 1)
        XCTAssertFalse(ImportContextBudget.textFits(text))
    }

    // MARK: - mapItemToRow: valid items map with correct, category-scoped details keys

    func testValidFlightItemMapsWithFlightDetailsOnly() {
        let raw = makeRawItem(
            category: "flight", title: "TAP TP1234",
            startsAt: "2026-07-14T09:00:00-04:00", endsAt: "2026-07-14T20:15:00+01:00",
            tz: "America/New_York", locationName: "JFK", confirmation: " QK7P2M ",
            airline: "TAP Air Portugal", flightNo: "TP1234", fromIATA: "JFK", toIATA: "LIS",
            seat: "14A", terminal: "4", gate: "B12", arrivalTz: "Europe/Lisbon",
            // Populated but category-irrelevant — must NOT leak into `details`.
            room: "301", ticketRef: "T-1", partySize: 4, reservationName: "Smith",
            provider: "Hertz", dropoffLocation: "Airport", address: "1 Main St"
        )
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }

        XCTAssertEqual(row.category, .flight)
        XCTAssertEqual(row.title, "TAP TP1234")
        XCTAssertEqual(row.tz, "America/New_York")
        XCTAssertEqual(row.locationName, "JFK")
        XCTAssertEqual(row.confirmation, "QK7P2M", "confirmation should be trimmed")
        XCTAssertNotNil(row.endsAt)

        // Flight-relevant keys survive...
        XCTAssertEqual(row.details.airline, "TAP Air Portugal")
        XCTAssertEqual(row.details.flightNo, "TP1234")
        XCTAssertEqual(row.details.fromIATA, "JFK")
        XCTAssertEqual(row.details.toIATA, "LIS")
        XCTAssertEqual(row.details.seat, "14A")
        XCTAssertEqual(row.details.terminal, "4")
        XCTAssertEqual(row.details.gate, "B12")
        XCTAssertEqual(row.details.arrivalTz, "Europe/Lisbon")
        // ...every other category's keys never emitted, even though the raw
        // item carried values for them (this milestone's brief: "details
        // filtered to the exact keys ItineraryItem+Details.swift reads").
        XCTAssertNil(row.details.room)
        XCTAssertNil(row.details.ticketRef)
        XCTAssertNil(row.details.partySize)
        XCTAssertNil(row.details.reservationName)
        XCTAssertNil(row.details.provider)
        XCTAssertNil(row.details.dropoffLocation)
        XCTAssertNil(row.details.address)
    }

    func testValidHotelItemMapsWithRoomOnly() {
        let raw = makeRawItem(
            category: "hotel", title: "Memmo Alfama", tz: "Europe/Lisbon",
            airline: "should not leak", room: "Deluxe 502", ticketRef: "should not leak"
        )
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(row.category, .hotel)
        XCTAssertEqual(row.details.room, "Deluxe 502")
        XCTAssertNil(row.details.airline)
        XCTAssertNil(row.details.ticketRef)
    }

    func testValidFoodItemMapsWithFoodDetailsOnly() {
        let raw = makeRawItem(
            category: "food", title: "Dinner at Cervejaria", tz: "Europe/Lisbon",
            room: "should not leak", partySize: 4, reservationName: "Silva",
            provider: "should not leak", address: "Rua X 12"
        )
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(row.category, .food)
        XCTAssertEqual(row.details.partySize, 4)
        XCTAssertEqual(row.details.reservationName, "Silva")
        XCTAssertEqual(row.details.address, "Rua X 12")
        XCTAssertNil(row.details.room)
        XCTAssertNil(row.details.provider)
    }

    func testValidTransportItemMapsWithTransportDetailsOnly() {
        let raw = makeRawItem(
            category: "transport", title: "Rental car", tz: "Europe/Lisbon",
            arrivalTz: "Europe/Lisbon", room: "should not leak", ticketRef: "should not leak",
            provider: "Hertz", dropoffLocation: "Porto"
        )
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(row.category, .transport)
        XCTAssertEqual(row.details.provider, "Hertz")
        XCTAssertEqual(row.details.dropoffLocation, "Porto")
        XCTAssertEqual(row.details.arrivalTz, "Europe/Lisbon")
        XCTAssertNil(row.details.room)
        XCTAssertNil(row.details.ticketRef)
    }

    func testValidActivityItemMapsWithActivityDetailsOnly() {
        let raw = makeRawItem(
            category: "activity", title: "Aquarium", tz: "Asia/Tokyo",
            room: "should not leak", ticketRef: "A-99", address: "Okinawa"
        )
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(row.category, .activity)
        XCTAssertEqual(row.details.ticketRef, "A-99")
        XCTAssertEqual(row.details.address, "Okinawa")
        XCTAssertNil(row.details.room)
    }

    // MARK: - mapItemToRow: rejection cases

    func testUnknownCategoryRejected() {
        let raw = makeRawItem(category: "shopping")
        XCTAssertNil(ImportExtraction.mapItemToRow(raw))
    }

    func testEmptyTitleRejected() {
        let raw = makeRawItem(title: "   ")
        XCTAssertNil(ImportExtraction.mapItemToRow(raw))
    }

    func testInvalidTimeZoneRejected() {
        let raw = makeRawItem(tz: "Not/AZone")
        XCTAssertNil(ImportExtraction.mapItemToRow(raw))
    }

    func testUnparseableStartsAtRejected() {
        let raw = makeRawItem(startsAt: "sometime next week")
        XCTAssertNil(ImportExtraction.mapItemToRow(raw))
    }

    func testEndsAtDroppedWhenUnparseableButRowStillValid() {
        let raw = makeRawItem(startsAt: "2026-07-14T09:00:00-04:00", endsAt: "not a date")
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertNil(row.endsAt, "an unparseable ends_at should be dropped, not fail the whole item")
    }

    func testEndsAtKeptWhenParseable() {
        let raw = makeRawItem(startsAt: "2026-07-14T09:00:00-04:00", endsAt: "2026-07-14T20:15:00+01:00")
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertNotNil(row.endsAt)
    }

    func testEmptyConfirmationAndLocationNormalizeToNilAndEmptyString() {
        let raw = makeRawItem(locationName: "  ", confirmation: "  ")
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(row.locationName, "", "matches backend's default: empty string, never nil")
        XCTAssertNil(row.confirmation)
    }

    // MARK: - mapPackingItem: label validation + group-key whitelist w/ custom fallback

    func testValidPackingItemPreservesKnownGroupKey() {
        let mapped = ImportExtraction.mapPackingItem(RawExtractedPackingItem(label: " Passport ", groupKey: "documents"))
        XCTAssertEqual(mapped?.label, "Passport")
        XCTAssertEqual(mapped?.groupKey, .documents)
    }

    func testEmptyPackingLabelRejected() {
        XCTAssertNil(ImportExtraction.mapPackingItem(RawExtractedPackingItem(label: "   ", groupKey: "documents")))
    }

    /// Mirrors backend's `ALLOWED_PACKING_GROUPS.has(...) ? it.group_key : "custom"`
    /// (`extract.ts`/`ingest-text/index.ts`) exactly — an unrecognized group
    /// key never rejects the item, it just falls back to `.custom`.
    func testUnknownPackingGroupKeyFallsBackToCustom() {
        let mapped = ImportExtraction.mapPackingItem(RawExtractedPackingItem(label: "Umbrella", groupKey: "electronics"))
        XCTAssertEqual(mapped?.label, "Umbrella")
        XCTAssertEqual(mapped?.groupKey, .custom)
    }

    // MARK: - ImportDateParsing

    func testParsesOffsetBearingTimestampRegardlessOfFallbackZone() {
        let date = ImportDateParsing.parse("2026-07-14T09:00:00-04:00", fallbackTz: TimeZone(identifier: "Asia/Tokyo")!)
        XCTAssertEqual(date?.timeIntervalSince1970, 1_784_034_000) // 2026-07-14T13:00:00Z
    }

    func testParsesUTCZuluTimestamp() {
        let date = ImportDateParsing.parse("2026-07-14T09:00:00Z", fallbackTz: TimeZone(identifier: "America/New_York")!)
        XCTAssertEqual(date?.timeIntervalSince1970, 1_784_019_600) // 2026-07-14T09:00:00Z
    }

    /// The common on-device case: the source text (and so the model's
    /// output) has no explicit UTC offset — read as wall-clock time in the
    /// item's own validated zone rather than rejected or silently
    /// mis-anchored to UTC (CLAUDE.md §7.4).
    func testFloatingTimestampReadAsWallClockInFallbackZone() {
        let nyTz = TimeZone(identifier: "America/New_York")!
        guard let date = ImportDateParsing.parse("2026-07-14T09:00:00", fallbackTz: nyTz) else {
            return XCTFail("expected a parsed date")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = nyTz
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 14)
        XCTAssertEqual(components.hour, 9)
        XCTAssertEqual(components.minute, 0)
    }

    func testFloatingDateOnlyReadAsMidnightInFallbackZone() {
        let nyTz = TimeZone(identifier: "America/New_York")!
        guard let date = ImportDateParsing.parse("2026-07-14", fallbackTz: nyTz) else {
            return XCTFail("expected a parsed date")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = nyTz
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 14)
        XCTAssertEqual(components.hour, 0)
    }

    func testGarbageAndEmptyDateStringsRejected() {
        let tz = TimeZone(identifier: "UTC")!
        XCTAssertNil(ImportDateParsing.parse("not a date", fallbackTz: tz))
        XCTAssertNil(ImportDateParsing.parse("", fallbackTz: tz))
        XCTAssertNil(ImportDateParsing.parse("   ", fallbackTz: tz))
        XCTAssertNil(ImportDateParsing.parse("2026-07-14T09:00:00 approx", fallbackTz: tz))
    }

    // MARK: - Fixture

    private func makeRawItem(
        category: String = "flight",
        title: String = "TAP TP1234",
        startsAt: String = "2026-07-14T09:00:00-04:00",
        endsAt: String? = nil,
        tz: String = "America/New_York",
        locationName: String? = nil,
        confirmation: String? = nil,
        airline: String? = nil,
        flightNo: String? = nil,
        fromIATA: String? = nil,
        toIATA: String? = nil,
        seat: String? = nil,
        terminal: String? = nil,
        gate: String? = nil,
        arrivalTz: String? = nil,
        room: String? = nil,
        ticketRef: String? = nil,
        partySize: Int? = nil,
        reservationName: String? = nil,
        provider: String? = nil,
        dropoffLocation: String? = nil,
        address: String? = nil
    ) -> RawExtractedItem {
        RawExtractedItem(
            category: category, title: title, startsAt: startsAt, endsAt: endsAt, tz: tz,
            locationName: locationName, confirmation: confirmation,
            airline: airline, flightNo: flightNo, fromIATA: fromIATA, toIATA: toIATA,
            seat: seat, terminal: terminal, gate: gate, arrivalTz: arrivalTz,
            room: room, ticketRef: ticketRef, partySize: partySize, reservationName: reservationName,
            provider: provider, dropoffLocation: dropoffLocation, address: address
        )
    }
}
