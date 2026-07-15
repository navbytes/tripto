import XCTest
@testable import Tripto

/// Tripto Archive v1 (docs/IMPORT_FORMAT.md, roadmap 2.2/2.3). Mirrors
/// `ImportExtractionTests`' shape for the sibling paste-import feature:
/// everything here is pure (`TripArchiveMapper`/`UUIDv5`/`TripArchiveExporter
/// .composeDocument`), no `ModelContainer` — see `TripArchiveImporterTests`
/// for the one file that touches SwiftData.
final class TripArchiveTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - UUIDv5 (RFC 4122 §4.3)

    /// The well-known worked example (DNS namespace + "www.example.com"),
    /// independently verified against Python's stdlib `uuid.uuid5` and a
    /// from-scratch SHA-1 + version/variant-bit computation — both agree on
    /// `2ED6657D-E927-568B-95E1-2665A8AEA6A2`.
    ///
    /// NOTE: the task brief's own quoted vector
    /// (`2ED6657D-E927-568B-95E3-50C977A978BF`) does not match this or any
    /// independent implementation; it appears to be a transcription error,
    /// not a real RFC 4122 v5 output. Flagged in the handoff — implementing
    /// the wrong value would have silently broken every derived id in the
    /// app (re-import idempotence depends on this function being a
    /// textbook-correct UUIDv5).
    func testUUIDv5MatchesTheRFC4122DNSNamespaceWorkedExample() {
        let dnsNamespace = UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!
        let result = UUIDv5.generate(namespace: dnsNamespace, name: "www.example.com")
        XCTAssertEqual(result.uuidString, "2ED6657D-E927-568B-95E1-2665A8AEA6A2")
    }

    func testUUIDv5IsDeterministicForTheSameNamespaceAndName() {
        let first = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:abc")
        let second = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:abc")
        XCTAssertEqual(first, second)
    }

    func testUUIDv5DiffersForDifferentNames() {
        let a = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:abc")
        let b = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:xyz")
        XCTAssertNotEqual(a, b)
    }

    func testUUIDv5DiffersForDifferentNamePrefixesEvenWithTheSameSuffix() {
        // trip:<id> vs item:<tripId>/<id> vs profile:<tripId>/<id> must not
        // collide just because the tail characters happen to match.
        let tripId = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:t/x")
        let itemId = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "item:t/x")
        let profileId = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "profile:t/x")
        XCTAssertEqual(Set([tripId, itemId, profileId]).count, 3)
    }

    // MARK: - Envelope decode + atomic bounds (§1)

    func testDecodeRejectsAFileOverFiveMegabytes() {
        let oversized = Data(repeating: 0x20, count: TripArchiveBounds.maxFileBytes + 1)
        XCTAssertThrowsError(try TripArchiveMapper.decode(oversized)) { error in
            XCTAssertEqual(error as? TripArchiveError, .fileTooLarge)
        }
    }

    func testDecodeRejectsWrongFormatString() throws {
        let document = ArchiveDocument(format: "some-other-format", version: 1, exportedAt: nil, trips: [])
        let data = try TripArchiveExporter.encode(document)
        XCTAssertThrowsError(try TripArchiveMapper.decode(data)) { error in
            XCTAssertEqual(error as? TripArchiveError, .wrongFormat)
        }
    }

    func testDecodeRefusesAVersionNewerThanTheAppUnderstands() throws {
        let document = ArchiveDocument(format: TripArchiveFormat.identifier, version: 2, exportedAt: nil, trips: [])
        let data = try TripArchiveExporter.encode(document)
        XCTAssertThrowsError(try TripArchiveMapper.decode(data)) { error in
            XCTAssertEqual(error as? TripArchiveError, .unsupportedVersion(2))
        }
    }

    func testDecodeRefusesVersionZeroOrNegative() throws {
        for version in [0, -1] {
            let document = ArchiveDocument(format: TripArchiveFormat.identifier, version: version, exportedAt: nil, trips: [])
            let data = try TripArchiveExporter.encode(document)
            XCTAssertThrowsError(try TripArchiveMapper.decode(data), "version \(version)") { error in
                XCTAssertEqual(error as? TripArchiveError, .unsupportedVersion(version))
            }
        }
    }

    /// `version` is a required (non-optional) Int on the envelope's
    /// synthesized `Decodable` — a hand-authored file that omits it
    /// entirely can't even reach the "unsupported version" branch, and must
    /// still fail atomically rather than crash or default silently.
    func testDecodeTreatsAMissingVersionKeyAsInvalidJSON() {
        let json = "{ \"format\": \"tripto-archive\", \"trips\": [] }"
        XCTAssertThrowsError(try TripArchiveMapper.decode(Data(json.utf8))) { error in
            XCTAssertEqual(error as? TripArchiveError, .invalidJSON)
        }
    }

    func testDecodeAcceptsVersionOneWithAnEmptyTripsArray() throws {
        let document = ArchiveDocument(format: TripArchiveFormat.identifier, version: 1, exportedAt: nil, trips: [])
        let data = try TripArchiveExporter.encode(document)
        let decoded = try TripArchiveMapper.decode(data)
        XCTAssertEqual(decoded.trips.count, 0)
    }

    func testDecodeRejectsMalformedJSONEntirely() {
        let data = Data("{ not json".utf8)
        XCTAssertThrowsError(try TripArchiveMapper.decode(data)) { error in
            XCTAssertEqual(error as? TripArchiveError, .invalidJSON)
        }
    }

    /// Not just syntactically-wrong JSON *text* — bytes that can never form
    /// valid UTF-8 at all (a lone 0xFF/0xFE lead byte). Same atomic-failure
    /// contract either way.
    func testDecodeRejectsDataThatIsNotValidUTF8() {
        let invalidUTF8 = Data([0xFF, 0xFE, 0x00, 0x7B, 0x7D])
        XCTAssertThrowsError(try TripArchiveMapper.decode(invalidUTF8)) { error in
            XCTAssertEqual(error as? TripArchiveError, .invalidJSON)
        }
    }

    func testDecodeRejectsTruncatedJSON() throws {
        let trip = makeArchiveTrip(items: [makeArchiveItem()])
        let document = ArchiveDocument(format: TripArchiveFormat.identifier, version: 1, exportedAt: nil, trips: [trip])
        let fullData = try TripArchiveExporter.encode(document)
        let truncated = Data(fullData.prefix(fullData.count / 2))
        XCTAssertThrowsError(try TripArchiveMapper.decode(truncated)) { error in
            XCTAssertEqual(error as? TripArchiveError, .invalidJSON)
        }
    }

    func testDecodeRejectsMoreThanTwoHundredTrips() throws {
        let trips = (0..<(TripArchiveBounds.maxTrips + 1)).map { makeArchiveTrip(id: "trip-\($0)") }
        let document = ArchiveDocument(format: TripArchiveFormat.identifier, version: 1, exportedAt: nil, trips: trips)
        let data = try TripArchiveExporter.encode(document)
        XCTAssertThrowsError(try TripArchiveMapper.decode(data)) { error in
            XCTAssertEqual(error as? TripArchiveError, .tooManyTrips(TripArchiveBounds.maxTrips + 1))
        }
    }

    func testDecodeRejectsMoreThanFiveHundredItemsInASingleTrip() throws {
        let items = (0..<(TripArchiveBounds.maxItemsPerTrip + 1)).map { makeArchiveItem(id: "item-\($0)") }
        let trip = makeArchiveTrip(id: "big-trip", items: items)
        let document = ArchiveDocument(format: TripArchiveFormat.identifier, version: 1, exportedAt: nil, trips: [trip])
        let data = try TripArchiveExporter.encode(document)
        XCTAssertThrowsError(try TripArchiveMapper.decode(data)) { error in
            XCTAssertEqual(error as? TripArchiveError, .tooManyItemsInTrip(tripId: "big-trip", count: TripArchiveBounds.maxItemsPerTrip + 1))
        }
    }

    /// The bound is inclusive — exactly 200 trips must still import, not
    /// just "up to 199".
    func testDecodeAcceptsExactlyTwoHundredTrips() throws {
        let trips = (0..<TripArchiveBounds.maxTrips).map { makeArchiveTrip(id: "trip-\($0)") }
        let document = ArchiveDocument(format: TripArchiveFormat.identifier, version: 1, exportedAt: nil, trips: trips)
        let data = try TripArchiveExporter.encode(document)
        let decoded = try TripArchiveMapper.decode(data)
        XCTAssertEqual(decoded.trips.count, TripArchiveBounds.maxTrips)
    }

    /// Same inclusive-bound check for the per-trip item cap.
    func testDecodeAcceptsExactlyFiveHundredItemsInASingleTrip() throws {
        let items = (0..<TripArchiveBounds.maxItemsPerTrip).map { makeArchiveItem(id: "item-\($0)") }
        let trip = makeArchiveTrip(id: "big-trip-ok", items: items)
        let document = ArchiveDocument(format: TripArchiveFormat.identifier, version: 1, exportedAt: nil, trips: [trip])
        let data = try TripArchiveExporter.encode(document)
        let decoded = try TripArchiveMapper.decode(data)
        XCTAssertEqual(decoded.trips.first?.items.count, TripArchiveBounds.maxItemsPerTrip)
    }

    /// A whole-file bounds/format violation refuses the ENTIRE import
    /// (§1) — distinct from a per-trip/per-item skip, which still imports
    /// everything else.
    func testDecodeFailureMeansNoTripsAreEverMapped() throws {
        let document = ArchiveDocument(format: "wrong", version: 1, exportedAt: nil, trips: [makeArchiveTrip()])
        let data = try TripArchiveExporter.encode(document)
        XCTAssertThrowsError(try TripArchiveMapper.decode(data))
    }

    // MARK: - Friendly error copy (§1/§6)

    /// Every atomic-failure case must produce actual user-facing copy (the
    /// Settings import-result alert shows `.message` verbatim) — not an
    /// empty string or a raw technical dump.
    func testEveryArchiveErrorHasANonEmptyUserFacingMessage() {
        let cases: [TripArchiveError] = [
            .invalidJSON, .wrongFormat, .unsupportedVersion(3), .fileTooLarge,
            .tooManyTrips(250), .tooManyItemsInTrip(tripId: "x", count: 600), .writeFailed
        ]
        for error in cases {
            XCTAssertFalse(error.message.isEmpty, "\(error)")
        }
    }

    // MARK: - Untrusted JSON at a trust boundary: wrong-typed fields degrade, never crash

    func testMalformedFieldTypesAreDroppedNotFatalToTheWholeArchive() throws {
        // `id` as a bare number and `party_size` as a string are both wrong
        // per the spec's types — a hand-authored or LLM-produced archive
        // could plausibly contain either. Neither should abort decoding of
        // the rest of the file.
        let json = """
        {
          "format": "tripto-archive",
          "version": 1,
          "trips": [
            {
              "id": 42,
              "title": "Numeric id trip",
              "start_date": "2026-01-01",
              "items": [
                { "id": "food-1", "category": "food", "starts_at": "2026-01-01T19:00", "tz": "UTC", "party_size": "four" }
              ]
            }
          ]
        }
        """
        let document = try TripArchiveMapper.decode(Data(json.utf8))
        XCTAssertEqual(document.trips.count, 1)
        // Coerced, not dropped — see `lenientString`'s defensive Int fallback.
        XCTAssertEqual(document.trips[0].id, "42")
        XCTAssertEqual(document.trips[0].items.count, 1)
        XCTAssertNil(document.trips[0].items[0].partySize)

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared[0].items.count, 1)
        XCTAssertNil(prepared[0].items[0].details.partySize)
        XCTAssertEqual(report.tripSkips, [])
        XCTAssertEqual(report.itemSkips, [])
    }

    /// No length bound exists anywhere in the mapper today — a very long
    /// title/notes value must still round-trip whole, not truncate or crash.
    /// D2/SEC fix: this test used to assert NO length limit at all (title/
    /// notes carried through verbatim at 50,000 chars) — since fixed per
    /// the security audit's LOW finding (an uncapped multi-MB string would
    /// get stored, synced, and rendered in the report sheet for no
    /// legitimate reason a conforming archive ever needs). Now asserts the
    /// clamp instead: trimmed to the documented bound, never failed or
    /// skipped — see the handoff's D2 section.
    func testVeryLongTitleAndNotesAreClampedRatherThanFailingOrCrashing() {
        let longTitle = String(repeating: "A", count: 50_000)
        let longNotes = String(repeating: "B", count: 50_000)
        let item = makeArchiveItem(category: "activity", startsAt: "2026-01-10T09:00", tz: "UTC", notes: longNotes)
        let trip = makeArchiveTrip(title: longTitle, items: [item])
        let document = makeDocument(trips: [trip])

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])

        XCTAssertEqual(prepared.first?.title.count, TripArchiveBounds.maxTitleLength)
        XCTAssertEqual(prepared.first?.items.first?.notes?.count, TripArchiveBounds.maxNotesLength)
        XCTAssertTrue(report.tripSkips.isEmpty)
        XCTAssertTrue(report.itemSkips.isEmpty)
    }

    /// Emoji + right-to-left script in the fields that flow straight through
    /// to stored rows — no normalization/mangling.
    func testTravellerNamesAndTripTitlesWithEmojiAndRTLTextAreCarriedThroughUnmangled() {
        let arabicName = "\u{0645}\u{0631}\u{064A}\u{0645}" // "مريم" (Maryam)
        let emojiTitle = "Family trip \u{1F3D6}\u{FE0F}\u{2708}\u{FE0F}" // "Family trip 🏖️✈️"
        let trip = makeArchiveTrip(id: "rtl-emoji", title: emojiTitle, travellers: [arabicName])
        let document = makeDocument(trips: [trip])

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])

        XCTAssertEqual(prepared.first?.title, emojiTitle)
        XCTAssertEqual(prepared.first?.profiles.first?.displayName, arabicName)
        XCTAssertEqual(report.profilesImported, 1)
    }

    /// The skip report carries the trip's title verbatim too (§6's per-trip
    /// skip list) — same unmangled-Unicode guarantee for report content,
    /// not just imported rows.
    func testCancelledTripSkipReportPreservesEmojiAndRTLTitleVerbatim() {
        let arabicTitle = "\u{0631}\u{062D}\u{0644}\u{0629} \u{1F30D}" // "رحلة 🌍" (Trip)
        let trip = makeArchiveTrip(title: arabicTitle, status: "cancelled")
        let document = makeDocument(trips: [trip])
        let (_, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(report.tripSkips.first?.title, arabicTitle)
    }

    // MARK: - §8 example: decode + map end to end

    private static let specExampleJSON = """
    {
      "format": "tripto-archive",
      "version": 1,
      "trips": [
        {
          "id": "2026-07-okinawa",
          "title": "Okinawa",
          "destination": "Okinawa, Japan",
          "country_code": "JP",
          "start_date": "2026-07-22",
          "end_date": "2026-07-26",
          "trip_type": "family",
          "status": "upcoming",
          "travellers": ["Asha", "Kiran", "Meera"],
          "items": [
            {
              "id": "uo844",
              "category": "flight",
              "starts_at": "2026-07-22T14:25",
              "ends_at": "2026-07-22T18:05",
              "airline": "HK Express",
              "flight_no": "UO844",
              "from_iata": "HKG",
              "to_iata": "OKA",
              "confirmation": "PNR001"
            },
            {
              "id": "car",
              "category": "transport",
              "title": "Rental car — Nissan X-trail (SUV)",
              "starts_at": "2026-07-22",
              "tz": "Asia/Tokyo",
              "provider": "Klook",
              "notes": "Booked 2026-04-01"
            }
          ]
        },
        {
          "id": "minimal",
          "title": "Weekend away",
          "start_date": "2025-03-01",
          "items": []
        }
      ]
    }
    """

    func testSpecExampleDecodesAndImportsBothTripsWithExpectedCounts() throws {
        let document = try TripArchiveMapper.decode(Data(Self.specExampleJSON.utf8))
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])

        XCTAssertEqual(prepared.count, 2)
        XCTAssertEqual(report.tripsImported, 2)
        XCTAssertEqual(report.itemsImported, 2)
        XCTAssertEqual(report.profilesImported, 3)
        XCTAssertTrue(report.tripSkips.isEmpty)
        XCTAssertTrue(report.itemSkips.isEmpty)

        let okinawa = try XCTUnwrap(prepared.first { $0.title == "Okinawa" })
        XCTAssertEqual(okinawa.id, UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:2026-07-okinawa"))
        XCTAssertEqual(okinawa.destination, "Okinawa, Japan")
        XCTAssertEqual(okinawa.countryCode, "JP")
        XCTAssertEqual(okinawa.startDate, DayDate(year: 2026, month: 7, day: 22))
        XCTAssertEqual(okinawa.endDate, DayDate(year: 2026, month: 7, day: 26))
        XCTAssertEqual(okinawa.tripType, .family)
        XCTAssertEqual(okinawa.profiles.map(\.displayName), ["Asha", "Kiran", "Meera"])
        for traveller in ["Asha", "Kiran", "Meera"] {
            let expected = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "profile:2026-07-okinawa/\(traveller)")
            XCTAssertTrue(okinawa.profiles.contains { $0.id == expected })
        }

        let minimal = try XCTUnwrap(prepared.first { $0.title == "Weekend away" })
        XCTAssertEqual(minimal.id, UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:minimal"))
        // No `end_date` in the source -> defaults to `start_date`.
        XCTAssertEqual(minimal.endDate, minimal.startDate)
        // No `destination` -> defaults to title.
        XCTAssertEqual(minimal.destination, "Weekend away")
        XCTAssertTrue(minimal.items.isEmpty)
        XCTAssertTrue(minimal.profiles.isEmpty)
    }

    /// The spec's own flight leg: HKG departure at a naive local
    /// `14:25`, zone resolved from `from_iata` (no explicit `tz`) ->
    /// Asia/Hong_Kong (UTC+8, no DST) -> `06:25Z`.
    func testSpecExampleFlightResolvesTheDocumentedUTCInstant() throws {
        let document = try TripArchiveMapper.decode(Data(Self.specExampleJSON.utf8))
        let (prepared, _) = TripArchiveMapper.map(document: document, existingTripIds: [])
        let okinawa = try XCTUnwrap(prepared.first { $0.title == "Okinawa" })
        let flight = try XCTUnwrap(okinawa.items.first { $0.category == .flight })

        let expectedStart = utc.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 6, minute: 25))!
        XCTAssertEqual(flight.startsAt, expectedStart)
        XCTAssertEqual(flight.tz, "Asia/Hong_Kong")
        // Arrival: to_iata OKA -> Asia/Tokyo (UTC+9) -> 18:05 local -> 09:05Z.
        let expectedEnd = utc.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 9, minute: 5))!
        XCTAssertEqual(flight.endsAt, expectedEnd)
        XCTAssertEqual(flight.details.arrivalTz, "Asia/Tokyo")
        XCTAssertEqual(flight.title, "HK Express UO844")
        XCTAssertEqual(flight.locationName, "HKG")
        XCTAssertEqual(flight.confirmation, "PNR001")
    }

    func testSpecExampleTransportItemUsesExplicitTzAndDateOnlyDefaultTime() throws {
        let document = try TripArchiveMapper.decode(Data(Self.specExampleJSON.utf8))
        let (prepared, _) = TripArchiveMapper.map(document: document, existingTripIds: [])
        let okinawa = try XCTUnwrap(prepared.first { $0.title == "Okinawa" })
        let car = try XCTUnwrap(okinawa.items.first { $0.category == .transport })

        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let components = tokyo.dateComponents([.year, .month, .day, .hour, .minute], from: car.startsAt)
        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 7)
        XCTAssertEqual(components.day, 22)
        XCTAssertEqual(components.hour, 10) // transport's date-only default
        XCTAssertEqual(components.minute, 0)
        XCTAssertEqual(car.tz, "Asia/Tokyo")
        XCTAssertEqual(car.details.provider, "Klook")
        XCTAssertEqual(car.notes, "Booked 2026-04-01")
    }

    /// §2: trip-level `notes` has no column in this app — dropped, reported,
    /// never carried onto `PreparedTrip`. The spec example doesn't itself
    /// carry trip notes, so this is a dedicated fixture.
    func testTripLevelNotesAreDroppedAndReported() {
        let trip = makeArchiveTrip(notes: "Booked through a travel agent, ref #4471")
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(report.droppedNotesCount, 1)
    }

    func testEmptyOrWhitespaceTripNotesAreNotCountedAsDropped() {
        let trip = makeArchiveTrip(notes: "   ")
        let document = makeDocument(trips: [trip])
        let (_, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(report.droppedNotesCount, 0)
    }

    // MARK: - Zone precedence (§4.1/§4.2): explicit tz > airport table > device fallback

    func testZonePrefersExplicitTzOverFromIATA() {
        // JFK would resolve America/New_York; explicit tz wins instead.
        let item = makeArchiveItem(category: "flight", startsAt: "2026-01-10T09:00", tz: "Europe/London", fromIATA: "JFK")
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: TimeZone(identifier: "Pacific/Auckland")!)
        XCTAssertEqual(prepared.first?.items.first?.tz, "Europe/London")
        XCTAssertEqual(report.zoneAssumedCount, 0)
    }

    func testZoneFallsBackToFromIATAWhenNoExplicitTz() {
        let item = makeArchiveItem(category: "flight", startsAt: "2026-01-10T09:00", fromIATA: "JFK")
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: TimeZone(identifier: "Pacific/Auckland")!)
        XCTAssertEqual(prepared.first?.items.first?.tz, "America/New_York")
        XCTAssertEqual(report.zoneAssumedCount, 0)
    }

    func testZoneFallsBackToDeviceZoneAndFlagsItWhenNeitherTzNorAirportResolves() {
        let item = makeArchiveItem(category: "activity", startsAt: "2026-01-10T09:00")
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: TimeZone(identifier: "Pacific/Auckland")!)
        XCTAssertEqual(prepared.first?.items.first?.tz, "Pacific/Auckland")
        XCTAssertEqual(report.zoneAssumedCount, 1)
    }

    func testZoneFallsBackToDeviceForAnUnknownAirportCode() {
        let item = makeArchiveItem(category: "flight", startsAt: "2026-01-10T09:00", fromIATA: "ZZZ")
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: TimeZone(identifier: "Pacific/Auckland")!)
        XCTAssertEqual(prepared.first?.items.first?.tz, "Pacific/Auckland")
        XCTAssertEqual(report.zoneAssumedCount, 1)
    }

    func testEndZoneFallsBackToStartZoneNotDeviceZoneWhenUnresolved() throws {
        // Hotel has no `arrival_tz`/`to_iata` at all, so its `ends_at` must
        // fall through rule 2 to "same zone as starts_at" (Lisbon) — never
        // the device zone (Auckland, ~13h off in January), and never
        // counted in `zoneAssumedCount` (that flag is starts_at-only).
        let item = makeArchiveItem(
            category: "hotel", startsAt: "2026-01-10T15:00", endsAt: "2026-01-12T11:00", tz: "Europe/Lisbon"
        )
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: TimeZone(identifier: "Pacific/Auckland")!)
        let mapped = try XCTUnwrap(prepared.first?.items.first)

        var lisbon = Calendar(identifier: .gregorian)
        lisbon.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        let expectedEnd = lisbon.date(from: DateComponents(year: 2026, month: 1, day: 12, hour: 11, minute: 0))!
        XCTAssertEqual(mapped.endsAt, expectedEnd)
        XCTAssertEqual(report.zoneAssumedCount, 0)
    }

    func testArrivalZonePrefersExplicitArrivalTzOverToIATA() {
        let item = makeArchiveItem(
            category: "flight", startsAt: "2026-01-10T09:00", endsAt: "2026-01-10T20:00",
            fromIATA: "JFK", toIATA: "LHR", arrivalTz: "Europe/Paris"
        )
        let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertEqual(prepared.first?.items.first?.details.arrivalTz, "Europe/Paris")
    }

    // MARK: - Cross-zone sanity: a naive wall-clock ends_at can look "earlier" than starts_at

    /// AKL -> HNL is the textbook "arrives before it leaves" itinerary: a
    /// ~23h zone-offset gap against a ~10h flight means the naive local
    /// arrival hour (09:00) is numerically earlier than the departure hour
    /// (22:00) on the very same date string. Neither instant depends on the
    /// other in `resolveItem` (each is resolved independently in its own
    /// zone), so this proves the STORED instants come out chronologically
    /// sane (end still after start), not that anything crashes on an
    /// assumption the code never makes.
    func testEndsAtWallClockLooksEarlierThanStartsAtWhenCrossingTheDateLineButTheStoredInstantIsStillLaterAndSane() throws {
        let item = makeArchiveItem(
            category: "flight", startsAt: "2026-03-10T22:00", endsAt: "2026-03-10T09:00",
            tz: "Pacific/Auckland", arrivalTz: "Pacific/Honolulu"
        )
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: .current)
        let mapped = try XCTUnwrap(prepared.first?.items.first)

        let expectedStart = utc.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 9, minute: 0))!
        let expectedEnd = utc.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 19, minute: 0))!
        XCTAssertEqual(mapped.startsAt, expectedStart)
        XCTAssertEqual(mapped.endsAt, expectedEnd)
        let unwrappedEnd = try XCTUnwrap(mapped.endsAt)
        XCTAssertGreaterThan(
            unwrappedEnd, mapped.startsAt,
            "the arrival instant is still chronologically after departure despite an earlier-looking naive wall clock"
        )
        XCTAssertTrue(report.itemSkips.isEmpty)
    }

    // MARK: - DST edges: naive local time falling in a spring-forward gap or fall-back overlap

    /// Southern-hemisphere spring-forward: at the 2026 Pacific/Auckland
    /// transition, local clocks jump from 01:59 NZST straight to 03:00 NZDT
    /// — wall-clock times in between (e.g. 02:30) never happened. Resolving
    /// a nonexistent local time deterministically yields no instant, which
    /// `resolveItem` treats the same as any other unparseable `starts_at`:
    /// the item is skipped and reported, never crashed or silently
    /// mis-anchored to the wrong side of the gap.
    func testStartsAtFallingInAPacificAucklandSpringForwardDSTGapIsSkippedDeterministically() {
        let item = makeArchiveItem(category: "activity", startsAt: "2026-09-27T02:30", tz: "Pacific/Auckland")
        let (firstPrepared, firstReport) = mapSingleItemTrip(item, deviceTimeZone: .current)
        let (secondPrepared, secondReport) = mapSingleItemTrip(item, deviceTimeZone: .current)

        XCTAssertTrue(firstPrepared.first?.items.isEmpty ?? false)
        XCTAssertEqual(firstReport.itemSkips.first?.reason, .noStartTime)
        XCTAssertEqual(firstReport, secondReport, "resolving the identical nonexistent local time twice must agree")
        XCTAssertEqual(firstPrepared, secondPrepared)
    }

    /// Same gap shape, the other Southern-hemisphere zone this feature
    /// ships (Australia's DST start lands a week later than NZ's, same
    /// 2am->3am jump).
    func testStartsAtFallingInAnAustraliaSydneySpringForwardDSTGapIsSkippedDeterministically() {
        let item = makeArchiveItem(category: "activity", startsAt: "2026-10-04T02:30", tz: "Australia/Sydney")
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertTrue(prepared.first?.items.isEmpty ?? false)
        XCTAssertEqual(report.itemSkips.first?.reason, .noStartTime)
    }

    /// Fall-back overlap: local 02:00-02:59 occurs twice at this transition
    /// (once at NZDT, once at NZST). Independently verified this resolves
    /// deterministically to the POST-transition (standard-time, UTC+12)
    /// occurrence — asserted as an exact, reproducible instant, not a guess
    /// at which side of the clock-change a human reader would assume.
    func testStartsAtFallingInAPacificAucklandFallBackDSTOverlapResolvesToADeterministicInstant() throws {
        let item = makeArchiveItem(category: "activity", startsAt: "2026-04-05T02:30", tz: "Pacific/Auckland")
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: .current)
        let mapped = try XCTUnwrap(prepared.first?.items.first)

        let expected = utc.date(from: DateComponents(year: 2026, month: 4, day: 4, hour: 14, minute: 30))!
        XCTAssertEqual(mapped.startsAt, expected)
        XCTAssertTrue(report.itemSkips.isEmpty)

        let (secondPass, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertEqual(secondPass.first?.items.first?.startsAt, expected, "resolving the same ambiguous wall clock twice must agree")
    }

    /// `ends_at` has no "invalid -> skip the item" rule (only `starts_at`
    /// does) — a gap-time `ends_at` degrades to `nil`, same as any other
    /// unparseable end time, and never sinks the item.
    func testEndsAtFallingInADSTGapDegradesToNilWithoutSkippingTheItem() throws {
        let item = makeArchiveItem(
            category: "activity", startsAt: "2026-09-26T20:00", endsAt: "2026-09-27T02:30", tz: "Pacific/Auckland"
        )
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: .current)
        let mapped = try XCTUnwrap(prepared.first?.items.first)
        XCTAssertNil(mapped.endsAt)
        XCTAssertTrue(report.itemSkips.isEmpty)
    }

    // MARK: - Leap-day dates

    func testARealLeapDayStartDateMapsToTheExactDayWithNoRollover() {
        let trip = makeArchiveTrip(id: "leap", startDate: "2028-02-29", endDate: "2028-03-02")
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(prepared.first?.startDate, DayDate(year: 2028, month: 2, day: 29))
        XCTAssertTrue(report.tripSkips.isEmpty)
    }

    func testALeapDayItemStartTimeResolvesToTheExactInstantWithoutCrashing() throws {
        let item = makeArchiveItem(category: "activity", startsAt: "2028-02-29T10:00", tz: "UTC")
        let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        let mapped = try XCTUnwrap(prepared.first?.items.first)
        let expected = utc.date(from: DateComponents(year: 2028, month: 2, day: 29, hour: 10, minute: 0))!
        XCTAssertEqual(mapped.startsAt, expected)
    }

    /// D2/M2 fix: not a real calendar date (2026 isn't a leap year). This
    /// USED to sail through — `DayDate.parse` (shared app-wide) does no
    /// month/day range validation, so `Calendar.date(from:)` silently
    /// rolled it forward to March 1st with no skip reported (pinned by
    /// `TripArchiveImporterTests.testFebruaryTwentyNinthInANonLeapYearSilentlyNormalizesToMarchFirstOnImport`,
    /// now updated to assert the fixed behavior instead). The mapper now
    /// validates the parsed day round-trips through `Calendar` before
    /// accepting it (`validCalendarDay`), so this is skipped per §2 like
    /// any other invalid `start_date` — meaning this test's own NAME/intent
    /// flipped from "documents current (wrong) behavior" to "proves the fix";
    /// see the handoff's D2 section.
    func testFebruaryTwentyNinthInANonLeapYearIsNowSkippedAsInvalid() {
        let trip = makeArchiveTrip(id: "fake-leap", startDate: "2026-02-29")
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertTrue(prepared.isEmpty)
        XCTAssertEqual(report.tripSkips.first?.reason, .noStartDate)
    }

    /// Sibling out-of-range case from the reviewer's own example — month 13,
    /// day 45 — which used to roll forward to 2027-02-14 (empirically
    /// confirmed pre-fix) instead of being rejected.
    func testOutOfRangeMonthAndDayIsSkippedAsInvalid() {
        let trip = makeArchiveTrip(id: "out-of-range", startDate: "2026-13-45")
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertTrue(prepared.isEmpty)
        XCTAssertEqual(report.tripSkips.first?.reason, .noStartDate)
    }

    /// An invalid `end_date` (present but calendar-invalid) degrades to the
    /// same "default to start_date" fallback as a MISSING end_date, rather
    /// than either crashing or silently keeping a rolled-forward date —
    /// §2 only requires `start_date`.
    func testInvalidEndDateFallsBackToStartDateRatherThanRollingForward() {
        let trip = makeArchiveTrip(id: "bad-end", startDate: "2026-06-01", endDate: "2026-02-30")
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(prepared.first?.endDate, DayDate(year: 2026, month: 6, day: 1))
        XCTAssertTrue(report.tripSkips.isEmpty)
    }

    // MARK: - Date-only category default times (§4.4)

    func testDateOnlyStartTimeDefaultsPerCategory() throws {
        let cases: [(String, Int, Int)] = [
            ("flight", 9, 0), ("hotel", 15, 0), ("activity", 10, 0), ("food", 19, 0), ("transport", 10, 0)
        ]
        for (category, hour, minute) in cases {
            let item = makeArchiveItem(category: category, startsAt: "2026-03-01", tz: "UTC")
            let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
            let startsAt = try XCTUnwrap(prepared.first?.items.first?.startsAt)
            let components = utc.dateComponents([.hour, .minute], from: startsAt)
            XCTAssertEqual(components.hour, hour, "category \(category)")
            XCTAssertEqual(components.minute, minute, "category \(category)")
        }
    }

    /// The one explicitly-called-out exception: a hotel's date-only
    /// `ends_at` defaults to 11:00 (checkout), not the 15:00 start default.
    func testDateOnlyHotelEndsAtDefaultsToElevenAM() throws {
        let item = makeArchiveItem(category: "hotel", startsAt: "2026-03-01", endsAt: "2026-03-05", tz: "UTC")
        let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        let endsAt = try XCTUnwrap(prepared.first?.items.first?.endsAt)
        let components = utc.dateComponents([.month, .day, .hour, .minute], from: endsAt)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 5)
        XCTAssertEqual(components.hour, 11)
        XCTAssertEqual(components.minute, 0)
    }

    /// Every OTHER category's date-only `ends_at` isn't special-cased by
    /// §4.4 — the mapper reuses that category's own START default
    /// symmetrically (documented decision, T3 handoff) rather than
    /// inventing a new rule; activity's is 10:00, same as its start default.
    func testDateOnlyEndsAtForANonHotelCategoryReusesItsOwnStartDefaultTime() throws {
        let item = makeArchiveItem(category: "activity", startsAt: "2026-03-01", endsAt: "2026-03-03", tz: "UTC")
        let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        let endsAt = try XCTUnwrap(prepared.first?.items.first?.endsAt)
        let components = utc.dateComponents([.month, .day, .hour, .minute], from: endsAt)
        XCTAssertEqual(components.month, 3)
        XCTAssertEqual(components.day, 3)
        XCTAssertEqual(components.hour, 10)
        XCTAssertEqual(components.minute, 0)
    }

    func testFullISO8601OffsetWinsForTheInstantEvenWithAResolvedZone() throws {
        // tz says Europe/Lisbon, but starts_at carries its own +05:30
        // offset — §4.3: the explicit offset wins for the instant; the
        // resolved zone is still what's stored for display.
        let item = makeArchiveItem(category: "activity", startsAt: "2026-01-10T09:00:00+05:30", tz: "Europe/Lisbon")
        let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        let mapped = try XCTUnwrap(prepared.first?.items.first)
        let expected = try XCTUnwrap(ISO8601.withoutFractionalSeconds.date(from: "2026-01-10T09:00:00+05:30"))
        XCTAssertEqual(mapped.startsAt, expected)
        XCTAssertEqual(mapped.tz, "Europe/Lisbon")
    }

    // MARK: - Trip-level skips (§2, §5)

    func testCancelledTripIsSkippedAndReported() {
        let trip = makeArchiveTrip(status: "cancelled")
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertTrue(prepared.isEmpty)
        XCTAssertEqual(report.tripSkips, [.init(tripId: "trip-1", title: "Test trip", reason: .cancelled)])
    }

    func testCancelledStatusCheckIsCaseInsensitive() {
        let trip = makeArchiveTrip(status: "CANCELLED")
        let document = makeDocument(trips: [trip])
        let (prepared, _) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertTrue(prepared.isEmpty)
    }

    func testTripWithMissingStartDateIsSkippedAndReported() {
        let trip = makeArchiveTrip(startDate: nil)
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertTrue(prepared.isEmpty)
        XCTAssertEqual(report.tripSkips, [.init(tripId: "trip-1", title: "Test trip", reason: .noStartDate)])
    }

    func testTripWithInvalidStartDateStringIsSkipped() {
        let trip = makeArchiveTrip(startDate: "not-a-date")
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertTrue(prepared.isEmpty)
        XCTAssertEqual(report.tripSkips.first?.reason, .noStartDate)
    }

    func testUnknownTripTypeFallsBackToFamily() {
        let trip = makeArchiveTrip(tripType: "roadtrip")
        let document = makeDocument(trips: [trip])
        let (prepared, _) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(prepared.first?.tripType, .family)
    }

    func testUnknownCoverFallsBackToAStableRotationByTripIndex() {
        let trips = (0..<3).map { makeArchiveTrip(id: "t\($0)", cover: "not-a-real-gradient") }
        let document = makeDocument(trips: trips)
        let (prepared, _) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(prepared.map(\.coverGradient), ["dusk", "plum", "moss"])
    }

    func testKnownCoverIsPreservedCaseInsensitively() {
        let trip = makeArchiveTrip(cover: "PLUM")
        let document = makeDocument(trips: [trip])
        let (prepared, _) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(prepared.first?.coverGradient, "plum")
    }

    // MARK: - Item-level skips (§3)

    func testUnknownCategoryItemIsSkippedAndReported() {
        let item = makeArchiveItem(id: "weird", category: "cruise")
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertTrue(prepared.first?.items.isEmpty ?? false)
        // D2/UX#3: `itemLabel` best-effort-falls-back to the raw category
        // text when the category itself is invalid (no title given here).
        XCTAssertEqual(
            report.itemSkips,
            [.init(tripId: "trip-1", tripTitle: "Test trip", itemId: "weird", itemLabel: "cruise", reason: .unknownCategory)]
        )
    }

    func testItemWithMissingStartsAtIsSkippedAndReported() {
        let item = makeArchiveItem(id: "no-time", category: "activity", startsAt: nil)
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertTrue(prepared.first?.items.isEmpty ?? false)
        // D2/UX#3: category IS valid here, so `itemLabel` is the real
        // derived title ("Activity" — capitalized category, no title given).
        XCTAssertEqual(
            report.itemSkips,
            [.init(tripId: "trip-1", tripTitle: "Test trip", itemId: "no-time", itemLabel: "Activity", reason: .noStartTime)]
        )
    }

    func testItemWithUnparseableStartsAtIsSkipped() {
        let item = makeArchiveItem(category: "activity", startsAt: "sometime next week")
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertTrue(prepared.first?.items.isEmpty ?? false)
        XCTAssertEqual(report.itemSkips.first?.reason, .noStartTime)
    }

    func testInvalidEndsAtDegradesToNilRatherThanSkippingTheItem() {
        let item = makeArchiveItem(category: "activity", startsAt: "2026-01-10T09:00", endsAt: "garbage", tz: "UTC")
        let (prepared, report) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertEqual(prepared.first?.items.count, 1)
        XCTAssertNil(prepared.first?.items.first?.endsAt)
        XCTAssertTrue(report.itemSkips.isEmpty)
    }

    func testOneBadItemDoesNotSinkTheRestOfTheTrip() {
        let good = makeArchiveItem(id: "good", category: "activity", startsAt: "2026-01-10", tz: "UTC")
        let bad = makeArchiveItem(id: "bad", category: "cruise", startsAt: "2026-01-11", tz: "UTC")
        let trip = makeArchiveTrip(items: [good, bad])
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(prepared.first?.items.count, 1)
        XCTAssertEqual(report.itemSkips.count, 1)
        // The trip itself still imports.
        XCTAssertEqual(report.tripsImported, 1)
    }

    // MARK: - D2/H1: a non-object `items[]` element (untrusted JSON at a trust boundary)

    /// The exact HIGH the reviewer flagged: `"items": [ {..valid..}, null,
    /// "oops", {..valid..} ]` used to make the ENTIRE array decode fail,
    /// caught by a `try? ... ?? []`, silently reporting zero items with no
    /// skip and no atomic failure. Now each non-object element degrades to
    /// its own `.unreadable` item skip and the well-formed siblings still
    /// import — "tests both ways" per the fix's own contract.
    func testNonObjectItemsArrayElementsAreSkippedAndReportedWithoutDroppingWellFormedSiblings() throws {
        let json = """
        {
          "format": "tripto-archive",
          "version": 1,
          "trips": [
            {
              "id": "mixed",
              "title": "Mixed",
              "start_date": "2026-01-01",
              "items": [
                { "id": "good1", "category": "activity", "starts_at": "2026-01-01T09:00", "tz": "UTC" },
                null,
                "oops",
                { "id": "good2", "category": "food", "starts_at": "2026-01-01T19:00", "tz": "UTC" }
              ]
            }
          ]
        }
        """
        let document = try TripArchiveMapper.decode(Data(json.utf8))
        // The decode layer itself: 2 well-formed items decoded, 2 slots lost.
        XCTAssertEqual(document.trips.first?.items.count, 2)
        XCTAssertEqual(document.trips.first?.unreadableItemCount, 2)

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])

        // Both directions: the well-formed items still import...
        XCTAssertEqual(prepared.first?.items.count, 2)
        XCTAssertEqual(report.itemsImported, 2)
        // ...and each malformed element is reported, not silently dropped.
        let unreadableSkips = report.itemSkips.filter { $0.reason == .unreadable }
        XCTAssertEqual(unreadableSkips.count, 2)
        XCTAssertTrue(unreadableSkips.allSatisfy { $0.tripId == "mixed" && $0.tripTitle == "Mixed" })
        // The trip itself is NOT sunk by the malformed elements.
        XCTAssertEqual(report.tripsImported, 1)
    }

    /// A trip whose `items` are ALL well-formed reports zero unreadable
    /// items — the fix doesn't false-positive on ordinary archives.
    func testAllWellFormedItemsReportZeroUnreadableItems() throws {
        let json = """
        {
          "format": "tripto-archive",
          "version": 1,
          "trips": [
            {
              "id": "clean",
              "title": "Clean",
              "start_date": "2026-01-01",
              "items": [
                { "id": "i1", "category": "activity", "starts_at": "2026-01-01T09:00", "tz": "UTC" },
                { "id": "i2", "category": "food", "starts_at": "2026-01-01T19:00", "tz": "UTC" }
              ]
            }
          ]
        }
        """
        let document = try TripArchiveMapper.decode(Data(json.utf8))
        XCTAssertEqual(document.trips.first?.unreadableItemCount, 0)
        let (_, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertTrue(report.itemSkips.filter { $0.reason == .unreadable }.isEmpty)
        XCTAssertEqual(report.itemsImported, 2)
    }

    /// A trip whose `items` value is present but isn't even an array (e.g.
    /// a bare string) degrades to zero items rather than throwing — the
    /// existing, unchanged behavior for a structurally-broken `items` key
    /// itself (distinct from one bad ELEMENT within a well-formed array,
    /// which is what H1 fixes).
    func testItemsValueThatIsNotAnArrayDegradesToZeroItemsWithoutThrowing() throws {
        let json = """
        {
          "format": "tripto-archive",
          "version": 1,
          "trips": [
            { "id": "weird-items", "title": "Weird", "start_date": "2026-01-01", "items": "not an array" }
          ]
        }
        """
        let document = try TripArchiveMapper.decode(Data(json.utf8))
        XCTAssertEqual(document.trips.first?.items.count, 0)
        XCTAssertEqual(document.trips.first?.unreadableItemCount, 0)
    }

    // MARK: - Defensive dedup within one archive (untrusted-input hardening)

    /// A malformed archive repeating the same trip `id` would otherwise
    /// derive the same UUIDv5 twice and violate `Trip.id`'s unique
    /// constraint at save time — failing the whole batch, not just this
    /// trip. The mapper dedupes up front instead.
    func testDuplicateTripIdWithinOneArchiveOnlyImportsTheFirstOccurrence() {
        let first = makeArchiveTrip(id: "dup", title: "First")
        let second = makeArchiveTrip(id: "dup", title: "Second")
        let document = makeDocument(trips: [first, second])

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.title, "First")
        XCTAssertEqual(report.tripsImported, 1)
        // P6.1: a same-archive repeat matches neither idempotence rule, so
        // `existingLocalTripId` stays nil — there's genuinely nothing local
        // to open yet (default value, matches production for this branch).
        XCTAssertEqual(report.tripSkips, [.init(tripId: "dup", title: "Second", reason: .alreadyImported)])
        XCTAssertNil(report.tripSkips.first?.existingLocalTripId)
    }

    /// D2/reviewer L6: a duplicate id's FIRST occurrence being skipped for
    /// an UNRELATED reason (cancelled) must not "consume the slot" and
    /// wrongly block a later, genuinely valid occurrence of the same id —
    /// the dedup guard only claims a trip's slot once it actually clears
    /// every other check, not the moment a duplicate is merely seen.
    func testDuplicateTripIdWhoseFirstOccurrenceIsCancelledStillLetsTheSecondValidOccurrenceImport() {
        let cancelledFirst = makeArchiveTrip(id: "dup-2", title: "Cancelled copy", status: "cancelled")
        let validSecond = makeArchiveTrip(id: "dup-2", title: "Valid copy")
        let document = makeDocument(trips: [cancelledFirst, validSecond])

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(prepared.first?.title, "Valid copy")
        XCTAssertEqual(report.tripsImported, 1)
        XCTAssertEqual(report.tripSkips, [.init(tripId: "dup-2", title: "Cancelled copy", reason: .cancelled)])
    }

    func testDuplicateItemIdWithinOneTripOnlyKeepsTheFirstOccurrence() {
        let first = makeArchiveItem(id: "dup-item", category: "activity", startsAt: "2026-01-01T09:00", tz: "UTC", locationName: "First")
        let second = makeArchiveItem(id: "dup-item", category: "food", startsAt: "2026-01-01T19:00", tz: "UTC", locationName: "Second")
        let trip = makeArchiveTrip(items: [first, second])
        let document = makeDocument(trips: [trip])

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])

        XCTAssertEqual(prepared.first?.items.count, 1)
        XCTAssertEqual(prepared.first?.items.first?.locationName, "First")
        XCTAssertEqual(report.itemsImported, 1)
    }

    func testDuplicateTravellerNameWithinOneTripOnlyKeepsOneProfile() {
        let trip = makeArchiveTrip(travellers: ["Asha", "Asha"])
        let document = makeDocument(trips: [trip])

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])

        XCTAssertEqual(prepared.first?.profiles.count, 1)
        XCTAssertEqual(report.profilesImported, 1)
    }

    // MARK: - Titles/locations (§3)

    func testFlightTitleDefaultsToAirlineAndFlightNumber() {
        let item = makeArchiveItem(category: "flight", startsAt: "2026-01-10T09:00", tz: "UTC", airline: "TAP Air Portugal", flightNo: "TP1234")
        let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertEqual(prepared.first?.items.first?.title, "TAP Air Portugal TP1234")
    }

    func testFlightTitleFallsBackToFromToWhenNoAirlineOrFlightNumber() {
        let item = makeArchiveItem(category: "flight", startsAt: "2026-01-10T09:00", tz: "UTC", fromIATA: "jfk", toIATA: "lis")
        let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertEqual(prepared.first?.items.first?.title, "Flight JFK\u{2013}LIS")
        XCTAssertEqual(prepared.first?.items.first?.locationName, "JFK")
    }

    func testNonFlightTitleDefaultsToCapitalizedCategory() {
        let item = makeArchiveItem(category: "hotel", startsAt: "2026-01-10", tz: "UTC")
        let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertEqual(prepared.first?.items.first?.title, "Hotel")
    }

    func testExplicitItemTitleIsNeverOverridden() {
        let item = makeArchiveItem(category: "flight", title: "My custom title", startsAt: "2026-01-10T09:00", tz: "UTC", airline: "TAP")
        let (prepared, _) = mapSingleItemTrip(item, deviceTimeZone: .current)
        XCTAssertEqual(prepared.first?.items.first?.title, "My custom title")
    }

    // MARK: - Travellers -> TripProfile rows (§2)

    func testTravellersBecomeProfileRowsWithStableRotatedAvatarColors() throws {
        let trip = makeArchiveTrip(travellers: ["Asha", "Kiran", "Meera", "Grandma", "Grandpa"])
        let document = makeDocument(trips: [trip])
        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [])
        let profiles = try XCTUnwrap(prepared.first).profiles
        XCTAssertEqual(profiles.map(\.displayName), ["Asha", "Kiran", "Meera", "Grandma", "Grandpa"])
        XCTAssertEqual(profiles.map(\.avatarColor), ["amber", "moss", "sky", "plum", "amber"])
        XCTAssertEqual(report.profilesImported, 5)
    }

    func testBlankTravellerNamesAreSkippedNotInsertedAsEmptyProfiles() {
        let trip = makeArchiveTrip(travellers: ["Asha", "   ", ""])
        let document = makeDocument(trips: [trip])
        let (prepared, _) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(prepared.first?.profiles.map(\.displayName), ["Asha"])
    }

    // MARK: - Idempotence & re-import (§5)

    func testATripAlreadyPresentLocallyIsSkippedWholeAndReportedAlreadyImported() {
        let trip = makeArchiveTrip(id: "dup-trip")
        let document = makeDocument(trips: [trip])
        let existingId = UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:dup-trip")

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [existingId])

        XCTAssertTrue(prepared.isEmpty)
        // P6.1: rule (a) (derived UUIDv5 match) — `existingLocalTripId` is
        // the matched local trip, backing the result sheet's "Open trip".
        XCTAssertEqual(
            report.tripSkips,
            [.init(tripId: "dup-trip", title: "Test trip", reason: .alreadyImported, existingLocalTripId: existingId)]
        )
        XCTAssertEqual(report.tripsImported, 0)
    }

    /// D1 / §5 rule (b): the archive's own `id`, taken at face value as a
    /// UUID, matches an existing local trip's row id directly — distinct
    /// from rule (a) (the *derived* UUIDv5 matching). This is exactly what
    /// makes importing your own fresh export a no-op on the FIRST pass,
    /// since export writes row UUIDs as archive ids and UUIDv5 has no
    /// fixed points (rule (a) alone can never catch this case).
    func testATripWhoseRawArchiveIdIsAUUIDMatchingAnExistingLocalTripIsSkippedAsAlreadyImported() {
        let existingLocalTripId = UUID()
        let trip = makeArchiveTrip(id: existingLocalTripId.uuidString, title: "My Own Export")
        let document = makeDocument(trips: [trip])

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [existingLocalTripId])

        XCTAssertTrue(prepared.isEmpty)
        // P6.1: rule (b) (raw-id match) also backs "Open trip".
        XCTAssertEqual(
            report.tripSkips,
            [.init(
                tripId: existingLocalTripId.uuidString, title: "My Own Export", reason: .alreadyImported,
                existingLocalTripId: existingLocalTripId
            )]
        )
    }

    /// The counterpart: an archive `id` that merely *looks* like a UUID
    /// (syntactically valid) but doesn't match anything local is a normal,
    /// fresh import — rule (b) must not false-positive on every UUID-shaped
    /// id, and the trip's identity is still the usual UUIDv5 derivation
    /// (not the raw UUID reused verbatim).
    func testAnArchiveIdThatIsAValidUUIDButMatchesNoLocalTripImportsNormally() {
        let unrelatedUUID = UUID()
        let trip = makeArchiveTrip(id: unrelatedUUID.uuidString, title: "Fresh Trip")
        let document = makeDocument(trips: [trip])

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [UUID()])

        XCTAssertEqual(prepared.count, 1)
        XCTAssertEqual(report.tripsImported, 1)
        XCTAssertEqual(
            prepared.first?.id,
            UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:\(unrelatedUUID.uuidString)")
        )
        XCTAssertNotEqual(prepared.first?.id, unrelatedUUID, "identity is still the derived UUIDv5, not the raw id reused verbatim")
    }

    /// `UUID`'s Equatable/Hashable compare the parsed 16 bytes, not the
    /// source string, so rule (b) must recognize a match regardless of the
    /// archive id's letter case.
    func testArchiveIdMatchingALocalTripIsRecognizedRegardlessOfUUIDStringCase() {
        let existingLocalTripId = UUID()
        let trip = makeArchiveTrip(id: existingLocalTripId.uuidString.lowercased(), title: "Case Test")
        let document = makeDocument(trips: [trip])

        let (prepared, report) = TripArchiveMapper.map(document: document, existingTripIds: [existingLocalTripId])

        XCTAssertTrue(prepared.isEmpty)
        XCTAssertEqual(report.tripSkips.first?.reason, .alreadyImported)
        // P6.1: the match still resolves to the correctly-cased local id,
        // not the lowercased archive string reused verbatim.
        XCTAssertEqual(report.tripSkips.first?.existingLocalTripId, existingLocalTripId)
    }

    func testReimportingTheSameArchiveTwiceCreatesZeroNewRowsTheSecondTime() {
        let document = makeDocument(trips: [
            makeArchiveTrip(id: "a", items: [makeArchiveItem(id: "i1", category: "activity", startsAt: "2026-01-01", tz: "UTC")]),
            makeArchiveTrip(id: "b")
        ])

        let (firstPass, firstReport) = TripArchiveMapper.map(document: document, existingTripIds: [])
        XCTAssertEqual(firstPass.count, 2)
        XCTAssertEqual(firstReport.tripsImported, 2)

        let existingIds = Set(firstPass.map(\.id))
        let (secondPass, secondReport) = TripArchiveMapper.map(document: document, existingTripIds: existingIds)

        XCTAssertTrue(secondPass.isEmpty)
        XCTAssertEqual(secondReport.tripsImported, 0)
        XCTAssertEqual(secondReport.tripSkips.count, 2)
        XCTAssertTrue(secondReport.tripSkips.allSatisfy { $0.reason == .alreadyImported })
    }

    // MARK: - Export -> import round trip (§7)

    /// D1 fix: §5 rule (b) — the archive id, taken as a UUID, matching a
    /// LOCAL trip directly. This is the "export your own data, then import
    /// that exact file back into the SAME device that still has the
    /// original" case, and is now a no-op on the very first pass (not just
    /// the second) — see `testExportThenReimportTwiceConvergesWithZeroNewRowsOnTheSecondPass`
    /// below for the complementary "original isn't present locally"
    /// scenario (fresh device / deleted-then-restored), where rule (a) is
    /// still what makes the *second* re-import idempotent.
    func testExportThenImportOnTheSameStoreIsANoOpOnTheFirstPassNow() throws {
        let tripId = UUID()
        let trip = TestFixtures.makeTrip(
            id: tripId, title: "Lisbon",
            startDate: utc.date(from: DateComponents(year: 2026, month: 5, day: 14))!,
            endDate: utc.date(from: DateComponents(year: 2026, month: 5, day: 20))!
        )
        let item = TestFixtures.makeItineraryItem(tripId: tripId, startsAt: .now)
        let profile = TripProfile(id: UUID(), tripId: tripId, displayName: "Grandma", avatarColor: "sky", linkedUserId: nil, createdAt: .now)
        let exported = TripArchiveExporter.composeDocument(trips: [trip], items: [item], profiles: [profile])
        let data = try TripArchiveExporter.encode(exported)
        let reDecoded = try TripArchiveMapper.decode(data)

        // The store still has the original row (`tripId`) — same-account,
        // same-device export-then-reimport.
        let (prepared, report) = TripArchiveMapper.map(document: reDecoded, existingTripIds: [tripId])

        XCTAssertTrue(prepared.isEmpty)
        XCTAssertEqual(report.tripsImported, 0)
        XCTAssertEqual(report.tripSkips.first?.reason, .alreadyImported)
    }

    /// UUIDv5 has no fixed points, so a natively-created trip's random v4
    /// `id` can't hash back to itself — when the ORIGINAL row isn't present
    /// locally (fresh device, or deleted-then-restored: `existingTripIds`
    /// is empty here, unlike the rule-(b) test above), the first import of
    /// a fresh export necessarily creates "new" (content-identical) rows
    /// under freshly derived ids. What UUIDv5 idempotence DOES guarantee,
    /// and what this test proves, is that re-importing that SAME exported
    /// archive a second time is the no-op: nothing balloons if a user taps
    /// Export-then-Import (or re-imports a backup) more than once.
    func testExportThenReimportTwiceConvergesWithZeroNewRowsOnTheSecondPass() throws {
        let tripId = UUID()
        let trip = TestFixtures.makeTrip(
            id: tripId, title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: utc.date(from: DateComponents(year: 2026, month: 5, day: 14))!,
            endDate: utc.date(from: DateComponents(year: 2026, month: 5, day: 20))!,
            coverGradient: "dusk", tripType: .family
        )
        let item = TestFixtures.makeItineraryItem(
            tripId: tripId, category: .flight, title: "TAP TP1234",
            startsAt: utc.date(from: DateComponents(year: 2026, month: 5, day: 14, hour: 8, minute: 20))!,
            tz: "America/New_York", locationName: "JFK", confirmation: "ABC123",
            details: ItemDetails(airline: "TAP", flightNo: "TP1234", fromIATA: "JFK", toIATA: "LIS")
        )
        let profile = TripProfile(id: UUID(), tripId: tripId, displayName: "Grandma", avatarColor: "sky", linkedUserId: nil, createdAt: .now)

        let today = utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let exported = TripArchiveExporter.composeDocument(trips: [trip], items: [item], profiles: [profile], today: today, calendar: utc)
        // Round-trip through real bytes, not just the in-memory struct, to
        // also prove the encode/decode wiring survives.
        let data = try TripArchiveExporter.encode(exported)
        let reDecoded = try TripArchiveMapper.decode(data)

        XCTAssertEqual(reDecoded.trips.first?.id, tripId.uuidString)
        XCTAssertEqual(reDecoded.trips.first?.status, "upcoming")
        XCTAssertEqual(reDecoded.trips.first?.travellers, ["Grandma"])

        let (firstImport, _) = TripArchiveMapper.map(document: reDecoded, existingTripIds: [])
        XCTAssertEqual(firstImport.count, 1)

        let (secondImport, secondReport) = TripArchiveMapper.map(document: reDecoded, existingTripIds: Set(firstImport.map(\.id)))
        XCTAssertTrue(secondImport.isEmpty)
        XCTAssertEqual(secondReport.tripSkips.first?.reason, .alreadyImported)
    }

    // MARK: - Test helpers

    private func makeDocument(trips: [ArchiveTrip]) -> ArchiveDocument {
        ArchiveDocument(format: TripArchiveFormat.identifier, version: TripArchiveFormat.supportedVersion, exportedAt: nil, trips: trips)
    }

    private func makeArchiveTrip(
        id: String = "trip-1", title: String? = "Test trip", destination: String? = nil,
        countryCode: String? = nil, startDate: String? = "2026-07-22", endDate: String? = nil,
        tripType: String? = nil, status: String? = nil, cover: String? = nil,
        travellers: [String]? = nil, items: [ArchiveItem] = [], notes: String? = nil
    ) -> ArchiveTrip {
        ArchiveTrip(
            id: id, title: title, destination: destination, countryCode: countryCode,
            startDate: startDate, endDate: endDate, tripType: tripType, status: status,
            cover: cover, travellers: travellers, items: items, notes: notes
        )
    }

    private func makeArchiveItem(
        id: String = "item-1", category: String? = "activity", title: String? = nil,
        startsAt: String? = "2026-07-22", endsAt: String? = nil, tz: String? = nil,
        locationName: String? = nil, confirmation: String? = nil, notes: String? = nil,
        airline: String? = nil, flightNo: String? = nil, fromIATA: String? = nil, toIATA: String? = nil,
        seat: String? = nil, terminal: String? = nil, gate: String? = nil, arrivalTz: String? = nil,
        room: String? = nil, ticketRef: String? = nil, partySize: Int? = nil, reservationName: String? = nil,
        provider: String? = nil, dropoffLocation: String? = nil, address: String? = nil
    ) -> ArchiveItem {
        ArchiveItem(
            id: id, category: category, title: title, startsAt: startsAt, endsAt: endsAt, tz: tz,
            locationName: locationName, confirmation: confirmation, notes: notes,
            airline: airline, flightNo: flightNo, fromIATA: fromIATA, toIATA: toIATA,
            seat: seat, terminal: terminal, gate: gate, arrivalTz: arrivalTz,
            room: room, ticketRef: ticketRef, partySize: partySize, reservationName: reservationName,
            provider: provider, dropoffLocation: dropoffLocation, address: address
        )
    }

    /// Wraps a single item in a single trip and maps it — the shape most of
    /// the item-resolution tests above need.
    private func mapSingleItemTrip(
        _ item: ArchiveItem, deviceTimeZone: TimeZone
    ) -> (trips: [PreparedTrip], report: TripArchiveImportReport) {
        let trip = makeArchiveTrip(items: [item])
        let document = makeDocument(trips: [trip])
        return TripArchiveMapper.map(document: document, existingTripIds: [], deviceTimeZone: deviceTimeZone)
    }
}
