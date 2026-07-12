import XCTest
@testable import Tripto

/// `Features/Trip/ImportExtraction.swift` — pure, OS-version-free, so every
/// case here runs with no model, no network, no FoundationModels (R4 §6:
/// "do not attempt to unit-test actual model calls; do NOT invent a mock of
/// Apple's session" — nothing here does either).
final class ImportExtractionTests: XCTestCase {
    // MARK: - Routing matrix (mode × availability × text-fits × consent-state)

    /// Full mode × 2x2x2 matrix. `.onDevice` mode is the original 2x2x2
    /// (availability × fit × consent) reinterpreted with the reason each
    /// `.remote` now carries; `.cloud` mode collapses all four
    /// availability×fit combinations to the same `remote(.cloudPreferred)`
    /// (PLAN.md Addendum: "Cloud mode → always remote(.cloudPreferred)").
    /// The consent dialog is required iff the route is `.remote` (any
    /// reason) and consent hasn't been granted — on-device NEVER requires
    /// it, regardless of consent state (this is the pure proof
    /// `AIImportConsent`'s doc comment on `PasteImportSheet.submit()`
    /// points at).
    func testRoutingMatrix() {
        struct Case {
            let mode: ImportProcessingMode
            let available: Bool
            let fits: Bool
            let consentGranted: Bool
            let route: ImportRoute
            let dialog: Bool
        }
        let cases: [Case] = [
            // mode == .onDevice
            Case(mode: .onDevice, available: true, fits: true, consentGranted: true, route: .onDevice, dialog: false),
            Case(mode: .onDevice, available: true, fits: true, consentGranted: false, route: .onDevice, dialog: false),
            Case(mode: .onDevice, available: true, fits: false, consentGranted: true, route: .remote(.tooLong), dialog: false),
            Case(mode: .onDevice, available: true, fits: false, consentGranted: false, route: .remote(.tooLong), dialog: true),
            Case(mode: .onDevice, available: false, fits: true, consentGranted: true, route: .remote(.unavailable), dialog: false),
            Case(mode: .onDevice, available: false, fits: true, consentGranted: false, route: .remote(.unavailable), dialog: true),
            Case(mode: .onDevice, available: false, fits: false, consentGranted: true, route: .remote(.unavailable), dialog: false),
            Case(mode: .onDevice, available: false, fits: false, consentGranted: false, route: .remote(.unavailable), dialog: true),
            // mode == .cloud: always cloudPreferred, regardless of
            // availability/fit — same 4 availability×fits combinations, to
            // prove none of them leak through as a different reason.
            Case(mode: .cloud, available: true, fits: true, consentGranted: true, route: .remote(.cloudPreferred), dialog: false),
            Case(mode: .cloud, available: true, fits: true, consentGranted: false, route: .remote(.cloudPreferred), dialog: true),
            Case(mode: .cloud, available: true, fits: false, consentGranted: true, route: .remote(.cloudPreferred), dialog: false),
            Case(mode: .cloud, available: false, fits: true, consentGranted: true, route: .remote(.cloudPreferred), dialog: false),
            Case(mode: .cloud, available: false, fits: false, consentGranted: false, route: .remote(.cloudPreferred), dialog: true)
        ]
        for testCase in cases {
            let route = ImportRouting.route(
                mode: testCase.mode, isOnDeviceAvailable: testCase.available, textFitsOnDevice: testCase.fits
            )
            XCTAssertEqual(
                route, testCase.route,
                "mode=\(testCase.mode) available=\(testCase.available) fits=\(testCase.fits) -> expected \(testCase.route)"
            )
            let dialog = ImportRouting.requiresConsentDialog(route: route, consentGranted: testCase.consentGranted)
            XCTAssertEqual(
                dialog, testCase.dialog,
                "route=\(route) consentGranted=\(testCase.consentGranted) -> expected dialog=\(testCase.dialog)"
            )
        }
    }

    /// PLAN.md Addendum: "cloud mode NEVER shows re-confirm." The reconfirm
    /// dialog (`PasteImportSheet.runRemoteFallbackAfterOnDeviceFailure()`)
    /// is only reachable from `submitOnDevice()`, which the Import button
    /// only calls when `currentRoute == .onDevice` — this is the pure proof
    /// that `route(mode: .cloud, ...)` can never produce that value, for
    /// ANY availability/fit combination, so the reconfirm path is
    /// unreachable in cloud mode by construction rather than by a runtime
    /// check anywhere. (Already implied by the `.cloud` rows in
    /// `testRoutingMatrix` above; kept as its own test so this specific,
    /// named requirement has one traceable, independently-failing pin.)
    func testCloudModeNeverRoutesOnDeviceRegardlessOfAvailabilityOrFit() {
        for available in [true, false] {
            for fits in [true, false] {
                XCTAssertNotEqual(
                    ImportRouting.route(mode: .cloud, isOnDeviceAvailable: available, textFitsOnDevice: fits), .onDevice,
                    "available=\(available) fits=\(fits): cloud mode must never route on-device"
                )
            }
        }
    }

    // MARK: - Footer variant selection (per route reason)

    /// PLAN.md Addendum: `.onDevice` keeps the existing on-this-iPhone
    /// promise line, unchanged.
    func testFooterVariantForOnDeviceRouteIsThePromiseLine() {
        XCTAssertEqual(ImportRouting.footerVariant(for: .onDevice), .onDevicePromise)
    }

    /// `.cloudPreferred` (explicit mode choice) and `.unavailable`
    /// (incapable device) both truthfully describe "this paste is going to
    /// the cloud," so they share the pre-existing remote-disclosure line
    /// rather than each inventing their own.
    func testFooterVariantForCloudPreferredAndUnavailableShareTheExistingRemoteDisclosure() {
        XCTAssertEqual(ImportRouting.footerVariant(for: .remote(.cloudPreferred)), .remoteDisclosure)
        XCTAssertEqual(ImportRouting.footerVariant(for: .remote(.unavailable)), .remoteDisclosure)
    }

    /// `.tooLong` is the one NEW copy state (PLAN.md Addendum): mode is
    /// `.onDevice`, on-device IS available, but this one paste still can't
    /// use it — the honest line, not the promise line.
    func testFooterVariantForTooLongIsTheHonestyLine() {
        XCTAssertEqual(ImportRouting.footerVariant(for: .remote(.tooLong)), .tooLongHonesty)
    }

    // MARK: - Context-window pre-estimate

    func testTextAtOrUnderBudgetFits() {
        // ASCII: 1 byte/char, so a byte budget behaves exactly like the old
        // char budget here.
        let text = String(repeating: "a", count: ImportContextBudget.maxPastedTextBytes)
        XCTAssertTrue(ImportContextBudget.textFits(text))
        XCTAssertTrue(ImportContextBudget.textFits(""))
    }

    func testTextOverBudgetDoesNotFit() {
        let text = String(repeating: "a", count: ImportContextBudget.maxPastedTextBytes + 1)
        XCTAssertFalse(ImportContextBudget.textFits(text))
    }

    /// Review fix (D2): a char-count budget wildly under-counts CJK scripts
    /// (~1 char/token, not ~3-4) — this Japanese text is short enough it
    /// would have "fit" under the OLD char-count budget (the same numeric
    /// value `maxPastedTextBytes` has now, just re-interpreted as bytes),
    /// but each of its characters is 3 UTF-8 bytes, so the fixed, byte-aware
    /// budget correctly rejects it and routes remote instead of silently
    /// overflowing on-device at runtime.
    func testLongJapaneseTextUnderOldCharLimitRoutesRemote() {
        let text = String(repeating: "\u{65C5}\u{884C}", count: 3000) // "旅行" (travel) x3000 = 6000 chars
        XCTAssertLessThan(
            text.count, ImportContextBudget.maxPastedTextBytes,
            "sanity: this would have fit the old character-count budget"
        )
        XCTAssertGreaterThan(
            text.utf8.count, ImportContextBudget.maxPastedTextBytes,
            "sanity: CJK is ~3 bytes/char, so this blows the byte budget"
        )
        XCTAssertFalse(ImportContextBudget.textFits(text))
        XCTAssertEqual(
            ImportRouting.route(mode: .onDevice, isOnDeviceAvailable: true, textFitsOnDevice: ImportContextBudget.textFits(text)),
            .remote(.tooLong)
        )
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

    // MARK: - Details encode direction: a mapped row's `details.json` wire
    // payload contains EXACTLY the expected snake_case keys and no others.
    //
    // The tests above assert the DECODE-adjacent Swift properties
    // (`row.details.flightNo == "..."` / `XCTAssertNil(row.details.room)`),
    // which already proves cross-category leakage doesn't happen at the
    // Swift-struct level. This section instead inspects what
    // `ItemDetails.json` (`ItineraryItem+Details.swift`) actually ENCODES
    // to the `itinerary_items.details` jsonb blob — the direction that
    // matters for what a pulled/synced row's wire payload really contains.
    // `ItemDetails.json` only emits a key when its backing field is
    // non-nil, so a stray field silently populated for the wrong category
    // would show up here as an extra key, not just a value the decode-side
    // tests above never happened to check.
    //
    // Two categories below carry one MORE key than the category groupings
    // in `RawExtractedItem`'s field comments suggest at a glance: `.food`
    // also writes the same shared `address` field `.activity` uses (both
    // read `raw.address`), and `.transport` also writes `arrivalTz` (the
    // drop-off zone, same field `.flight` uses for its arrival zone) — both
    // confirmed directly from `ImportExtraction.mapItemToRow`'s switch.

    private func detailsWireKeys(_ details: ItemDetails) -> Set<String> {
        guard case .object(let object) = details.json else {
            XCTFail("expected details.json to be a JSON object")
            return []
        }
        return Set(object.keys)
    }

    func testFlightDetailsEncodeExactlyItsEightWireKeys() {
        let raw = makeRawItem(
            category: "flight", tz: "America/New_York",
            airline: "TAP Air Portugal", flightNo: "TP1234", fromIATA: "JFK", toIATA: "LIS",
            seat: "14A", terminal: "4", gate: "B12", arrivalTz: "Europe/Lisbon"
        )
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(
            detailsWireKeys(row.details),
            ["airline", "flight_no", "from_iata", "to_iata", "seat", "terminal", "gate", "arrival_tz"]
        )
    }

    func testHotelDetailsEncodeExactlyRoom() {
        let raw = makeRawItem(category: "hotel", tz: "Europe/Lisbon", room: "Deluxe 502")
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(detailsWireKeys(row.details), ["room"])
    }

    func testActivityDetailsEncodeExactlyTicketRefAndAddress() {
        let raw = makeRawItem(category: "activity", tz: "Asia/Tokyo", ticketRef: "A-99", address: "Okinawa")
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(detailsWireKeys(row.details), ["ticket_ref", "address"])
    }

    /// See this section's header comment: `.food` also writes the shared
    /// `address` field, so its full wire key set is three keys.
    func testFoodDetailsEncodeExactlyPartySizeReservationNameAndAddress() {
        let raw = makeRawItem(
            category: "food", tz: "Europe/Lisbon", partySize: 4, reservationName: "Silva", address: "Rua X 12"
        )
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(detailsWireKeys(row.details), ["party_size", "reservation_name", "address"])
    }

    /// See this section's header comment: `.transport` also writes the
    /// shared `arrival_tz` field (the drop-off zone), so its full wire key
    /// set is three keys.
    func testTransportDetailsEncodeExactlyProviderDropoffLocationAndArrivalTz() {
        let raw = makeRawItem(
            category: "transport", tz: "Europe/Lisbon", arrivalTz: "Europe/Lisbon",
            provider: "Hertz", dropoffLocation: "Porto"
        )
        guard let row = ImportExtraction.mapItemToRow(raw) else { return XCTFail("expected a valid row") }
        XCTAssertEqual(detailsWireKeys(row.details), ["provider", "dropoff_location", "arrival_tz"])
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

    // MARK: - DST edge cases for floating (no-offset) timestamps
    //
    // These are regression PINS on Foundation's actual `DateFormatter`
    // behavior, not a claim that this is the "correct" way to resolve a
    // DST-affected floating time — `ImportDateParsing` only ever hands the
    // floating-format leg to a plain `DateFormatter` (no `Calendar`
    // involved), so whatever that formatter happens to do IS the app's
    // chosen semantics. Every expected value below was captured by running
    // the exact same formatter setup via `xcrun swift` (a throwaway probe
    // script, not hand arithmetic) — the coder's own verification note on
    // this file's date-parsing logic ("I initially hand-computed two epoch
    // values wrong — caught by running the formatter") applies just as much
    // here.

    /// 2026-03-08 is America/New_York's spring-forward day: clocks jump
    /// 2:00am straight to 3:00am, so every local wall-clock time from
    /// 02:00:00 through 02:59:59 that day never happens. Verified
    /// empirically that `DateFormatter` REJECTS a nonexistent local time
    /// outright (`date(from:)` returns `nil`) rather than snapping it to
    /// either side of the gap — confirmed at the exact boundary (01:59
    /// parses, 02:00-02:59 all fail, 03:00 parses again, and 01:59/03:00
    /// are exactly 60 seconds apart in real time, i.e. the entire missing
    /// hour truly vanishes). Because `ImportExtraction.mapItemToRow`
    /// requires a parseable `startsAt`, a booking whose extracted start
    /// time happens to land in this one-hour local gap is silently DROPPED
    /// from the import — same "unparseable -> whole item skipped" path as
    /// garbage text (`testUnparseableStartsAtRejected` above). Pinned so a
    /// future Foundation/ICU behavior change, or a switch to
    /// `Calendar`-based parsing, is caught rather than silently accepted.
    func testFloatingSpringForwardNonexistentLocalTimeFailsToParseEntirely() {
        let nyTz = TimeZone(identifier: "America/New_York")!
        XCTAssertNil(
            ImportDateParsing.parse("2026-03-08T02:30", fallbackTz: nyTz),
            "02:00-02:59 doesn't exist in America/New_York on 2026-03-08 (spring-forward) — " +
                "DateFormatter must reject it, not silently round to either side of the gap"
        )
        // Boundary confirmation: the gap is exactly this one hour, not a
        // wider parsing failure.
        XCTAssertEqual(
            ImportDateParsing.parse("2026-03-08T01:59:00", fallbackTz: nyTz)?.timeIntervalSince1970, 1_772_953_140
        )
        XCTAssertEqual(
            ImportDateParsing.parse("2026-03-08T03:00:00", fallbackTz: nyTz)?.timeIntervalSince1970, 1_772_953_200
        )
    }

    /// 2026-11-01 is America/New_York's fall-back day: clocks drop 2:00am
    /// back to 1:00am, so every local wall-clock time from 01:00:00 through
    /// 01:59:59 happens TWICE (once in EDT, once an hour later in EST).
    /// Verified empirically that `DateFormatter` resolves the ambiguous
    /// hour to its SECOND, standard-time (EST, UTC-5) occurrence rather
    /// than its first, daylight-time (EDT, UTC-4) one — pinned as the
    /// actual chosen semantics, not asserted as the objectively "right"
    /// choice between the two valid readings.
    func testFloatingFallBackAmbiguousLocalTimeResolvesToSecondStandardTimeOccurrence() {
        let nyTz = TimeZone(identifier: "America/New_York")!
        guard let date = ImportDateParsing.parse("2026-11-01T01:30", fallbackTz: nyTz) else {
            return XCTFail("the ambiguous hour must still parse (unlike the nonexistent spring-forward hour above), just to one specific instant")
        }
        XCTAssertEqual(date.timeIntervalSince1970, 1_793_514_600) // 2026-11-01T06:30:00Z
        XCTAssertEqual(
            nyTz.secondsFromGMT(for: date), -18_000,
            "resolved using EST (UTC-5, standard time / the SECOND occurrence), not EDT (UTC-4, the first)"
        )
    }

    /// Control case: an ordinary day with no DST transition in play round-
    /// trips a floating time to the exact intended wall-clock instant,
    /// contrasting the two edge cases above. Same fixture string
    /// `testFloatingTimestampReadAsWallClockInFallbackZone` already checks
    /// via decomposed wall-clock components; pinned here as the raw epoch
    /// instead (America/New_York is on daylight time, EDT/UTC-4, in July).
    func testFloatingNormalDayTimeRoundTripsToIntendedWallClockInstant() {
        let nyTz = TimeZone(identifier: "America/New_York")!
        XCTAssertEqual(
            ImportDateParsing.parse("2026-07-14T09:00", fallbackTz: nyTz)?.timeIntervalSince1970,
            1_784_034_000 // 2026-07-14T13:00:00Z == 09:00 EDT
        )
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
