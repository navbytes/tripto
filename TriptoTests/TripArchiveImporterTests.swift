import SwiftData
import XCTest
@testable import Tripto

/// SwiftData half of Tripto Archive v1 import (docs/IMPORT_FORMAT.md §6) —
/// everything else (decode/validate/map) is pure and covered by
/// `TripArchiveTests`; this file proves `TripArchiveImporter` actually turns
/// a `PreparedTrip` into real rows through an in-memory `ModelContainer`,
/// with `syncEngine: nil` (mirroring `DemoSeeder.seed`'s own `SyncEngine?`
/// signature) so nothing here ever touches the network.
@MainActor
final class TripArchiveImporterTests: XCTestCase {
    private func makeContext() -> ModelContext {
        ModelContext(AppSchema.makeContainer(inMemory: true))
    }

    private func makeDocument(trips: [ArchiveTrip]) -> ArchiveDocument {
        ArchiveDocument(format: TripArchiveFormat.identifier, version: TripArchiveFormat.supportedVersion, exportedAt: nil, trips: trips)
    }

    private func makeTrip(
        id: String, title: String = "Test trip", startDate: String? = "2026-09-01", status: String? = nil,
        travellers: [String]? = nil, items: [ArchiveItem] = []
    ) -> ArchiveTrip {
        ArchiveTrip(
            id: id, title: title, destination: nil, countryCode: nil, startDate: startDate, endDate: nil,
            tripType: nil, status: status, cover: nil, travellers: travellers, items: items, notes: nil
        )
    }

    private func makeItem(id: String, category: String = "activity", startsAt: String? = "2026-09-01T10:00", tz: String? = "Asia/Tokyo") -> ArchiveItem {
        ArchiveItem(
            id: id, category: category, title: nil, startsAt: startsAt, endsAt: nil, tz: tz,
            locationName: nil, confirmation: nil, notes: nil, airline: nil, flightNo: nil, fromIATA: nil, toIATA: nil,
            seat: nil, terminal: nil, gate: nil, arrivalTz: nil, room: nil, ticketRef: nil, partySize: nil,
            reservationName: nil, provider: nil, dropoffLocation: nil, address: nil
        )
    }

    func testImportCreatesTripItemAndProfileRowsWithExpectedStampsAndProvisionalMembership() async throws {
        let context = makeContext()
        let userId = UUID()
        let trip = makeTrip(id: "t1", title: "Kyoto", travellers: ["Asha"], items: [makeItem(id: "i1")])
        let data = try TripArchiveExporter.encode(makeDocument(trips: [trip]))

        let outcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)

        guard case .success(let report) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(report.tripsImported, 1)
        XCTAssertEqual(report.itemsImported, 1)
        XCTAssertEqual(report.profilesImported, 1)

        let storedTrip = try XCTUnwrap(try context.fetch(FetchDescriptor<Trip>()).first)
        XCTAssertEqual(storedTrip.title, "Kyoto")
        XCTAssertEqual(storedTrip.createdBy, userId)
        XCTAssertEqual(storedTrip.id, UUIDv5.generate(namespace: TripArchiveFormat.namespace, name: "trip:t1"))

        let items = try context.fetch(FetchDescriptor<ItineraryItem>())
        let storedItem = try XCTUnwrap(items.first)
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(storedItem.tripId, storedTrip.id)
        XCTAssertEqual(storedItem.statusRaw, ItemStatus.confirmed.rawValue)
        XCTAssertEqual(storedItem.sourceRaw, ItemSource.manual.rawValue)
        XCTAssertEqual(storedItem.createdBy, userId)

        let profiles = try context.fetch(FetchDescriptor<TripProfile>())
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles.first?.displayName, "Asha")
        XCTAssertEqual(profiles.first?.tripId, storedTrip.id)

        // Local-only provisional organizer membership (DemoSeeder/
        // TripFormView.save()'s exact pattern) — present locally so
        // offline role-gating works immediately, even though `syncEngine`
        // is nil here and nothing was pushed.
        let members = try context.fetch(FetchDescriptor<TripMember>())
        XCTAssertEqual(members.count, 1)
        XCTAssertEqual(members.first?.userId, userId)
        XCTAssertEqual(members.first?.role, .organizer)
        XCTAssertEqual(members.first?.tripId, storedTrip.id)
    }

    func testReimportingTheSameArchiveIntoTheSameStoreCreatesNoNewRows() async throws {
        let context = makeContext()
        let userId = UUID()
        let data = try TripArchiveExporter.encode(makeDocument(trips: [makeTrip(id: "again")]))

        _ = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)
        let secondOutcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)

        guard case .success(let report) = secondOutcome else {
            return XCTFail("expected success, got \(secondOutcome)")
        }
        XCTAssertEqual(report.tripsImported, 0)
        XCTAssertEqual(report.tripSkips.first?.reason, .alreadyImported)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 1)
    }

    /// D1 / §5 rule (b): a natively-created trip (random `UUID()` row id,
    /// same shape `TripFormView.save()` produces — not a prior import)
    /// already in the store, exported, then that exact export reimported
    /// into the SAME store — zero new trips/items/profiles, reported
    /// already-imported. This is the real "tap Export then Import trips
    /// again" user flow, not just a pure-mapper property.
    func testExportingAnExistingTripThenReimportingItIntoTheSameStoreCreatesNoNewRows() async throws {
        let context = makeContext()
        let userId = UUID()
        let tripId = UUID()
        let now = Date()

        let existingTrip = Trip(
            id: tripId, title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: now, endDate: now.addingTimeInterval(6 * 86_400), coverGradient: "dusk",
            tripTypeRaw: TripType.family.rawValue, createdBy: userId, createdAt: now, updatedAt: now, updatedBy: nil
        )
        let existingItem = ItineraryItem(
            id: UUID(), tripId: tripId, categoryRaw: ItemCategory.flight.rawValue, title: "TAP TP1234",
            startsAt: now, endsAt: nil, tz: "America/New_York", locationName: "JFK",
            locationLat: nil, locationLng: nil, confirmation: "ABC123", notes: nil,
            detailsJSON: "{}", statusRaw: ItemStatus.confirmed.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        let existingProfile = TripProfile(id: UUID(), tripId: tripId, displayName: "Grandma", avatarColor: "sky", linkedUserId: nil, createdAt: now)
        context.insert(existingTrip)
        context.insert(existingItem)
        context.insert(existingProfile)
        try context.save()

        let document = TripArchiveExporter.composeDocument(
            trips: try context.fetch(FetchDescriptor<Trip>()),
            items: try context.fetch(FetchDescriptor<ItineraryItem>()),
            profiles: try context.fetch(FetchDescriptor<TripProfile>())
        )
        let data = try TripArchiveExporter.encode(document)

        let outcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)

        guard case .success(let report) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(report.tripsImported, 0)
        XCTAssertEqual(report.itemsImported, 0)
        XCTAssertEqual(report.profilesImported, 0)
        XCTAssertEqual(report.tripSkips.first?.reason, .alreadyImported)

        // Still exactly the originals — nothing duplicated.
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItineraryItem>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<TripProfile>()).count, 1)
    }

    func testCancelledTripIsNeverInsertedIntoTheStore() async throws {
        let context = makeContext()
        let userId = UUID()
        let data = try TripArchiveExporter.encode(makeDocument(trips: [makeTrip(id: "c1", status: "cancelled")]))

        let outcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)

        guard case .success(let report) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(report.tripsImported, 0)
        XCTAssertEqual(report.tripSkips.first?.reason, .cancelled)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    /// A trip with an empty `items` array must still create the Trip row
    /// with zero `ItineraryItem` rows — not silently dropped, not crashed.
    func testImportOfATripWithNoItemsStillCreatesTheTripRowWithZeroItems() async throws {
        let context = makeContext()
        let userId = UUID()
        let data = try TripArchiveExporter.encode(makeDocument(trips: [makeTrip(id: "no-items")]))

        let outcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)

        guard case .success(let report) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(report.tripsImported, 1)
        XCTAssertEqual(report.itemsImported, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 1)
        XCTAssertTrue(try context.fetch(FetchDescriptor<ItineraryItem>()).isEmpty)
    }

    /// §1: `trips` may be empty — a valid, atomic no-op import, not a
    /// decode/validation failure.
    func testImportingAnArchiveWithAnEmptyTripsArrayIsANoOpSuccess() async throws {
        let context = makeContext()
        let data = try TripArchiveExporter.encode(makeDocument(trips: []))

        let outcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: UUID())

        guard case .success(let report) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(report, TripArchiveImportReport())
        XCTAssertTrue(try context.fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    func testAtomicFailureReturnsFailureAndInsertsNothing() async throws {
        let context = makeContext()
        let outcome = await TripArchiveImporter.importArchive(
            data: Data("not json".utf8), modelContext: context, syncEngine: nil, userId: UUID()
        )
        guard case .failure(let error) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertEqual(error, .invalidJSON)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    /// Truncated (not just syntactically-broken) JSON is the same atomic
    /// failure as any other malformed file — friendly error, zero rows.
    func testTruncatedArchiveFailsAtomicallyWithNoRowsInserted() async throws {
        let context = makeContext()
        let fullData = try TripArchiveExporter.encode(makeDocument(trips: [makeTrip(id: "t1", items: [makeItem(id: "i1")])]))
        let truncated = Data(fullData.prefix(fullData.count / 2))

        let outcome = await TripArchiveImporter.importArchive(
            data: truncated, modelContext: context, syncEngine: nil, userId: UUID()
        )

        guard case .failure(let error) = outcome else {
            return XCTFail("expected failure, got \(outcome)")
        }
        XCTAssertEqual(error, .invalidJSON)
        XCTAssertFalse(error.message.isEmpty)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    func testMultipleTripsInOneArchiveAllImportInASingleCall() async throws {
        let context = makeContext()
        let userId = UUID()
        let trips = (0..<5).map { makeTrip(id: "multi-\($0)", items: [makeItem(id: "item-\($0)")]) }
        let data = try TripArchiveExporter.encode(makeDocument(trips: trips))

        let outcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)

        guard case .success(let report) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(report.tripsImported, 5)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Trip>()).count, 5)
        XCTAssertEqual(try context.fetch(FetchDescriptor<ItineraryItem>()).count, 5)
    }

    /// A real leap day (2028 is a leap year) must survive the full
    /// import -> stored `Date` -> export round trip without drifting to an
    /// adjacent day through any timezone/rollover subtlety.
    func testALeapDayTripSurvivesImportThenExportWithoutDateDrift() async throws {
        let context = makeContext()
        let userId = UUID()
        let data = try TripArchiveExporter.encode(makeDocument(trips: [makeTrip(id: "leap-trip", startDate: "2028-02-29")]))

        _ = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)

        let storedTrip = try XCTUnwrap(try context.fetch(FetchDescriptor<Trip>()).first)
        let reexported = TripArchiveExporter.composeDocument(trips: [storedTrip], items: [], profiles: [])
        XCTAssertEqual(reexported.trips.first?.startDate, "2028-02-29")
    }

    /// D2/M2 fix: this test used to document Feb 29 (non-leap year)
    /// silently normalizing to March 1st on import (`DayDate.asDate()`'s
    /// `Calendar.date(from:)` rolling an invalid date forward). The mapper
    /// now rejects it before it ever reaches `DayDate.asDate()` — see
    /// `TripArchiveTests.testFebruaryTwentyNinthInANonLeapYearIsNowSkippedAsInvalid`
    /// for the pure-mapper version; this is the SwiftData-level proof that
    /// no trip row is created at all, not just that the report says skipped.
    func testFebruaryTwentyNinthInANonLeapYearIsSkippedNotImported() async throws {
        let context = makeContext()
        let userId = UUID()
        let data = try TripArchiveExporter.encode(makeDocument(trips: [makeTrip(id: "fake-leap", startDate: "2026-02-29")]))

        let outcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)
        guard case .success(let report) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(report.tripsImported, 0)
        XCTAssertEqual(report.tripSkips.first?.reason, .noStartDate)
        XCTAssertTrue(try context.fetch(FetchDescriptor<Trip>()).isEmpty)
    }

    /// P8a (avatar photos): the archive format has no per-traveller photo
    /// field (`docs/IMPORT_FORMAT.md` §2's `travellers` is a bare
    /// `[string]`, and stays that way — a storage path is meaningless
    /// outside this project, so it was never a candidate for the portable
    /// migration format). This pins the additive, intentional result: an
    /// imported traveller always gets `avatarPath == nil`, same as any other
    /// brand-new `TripProfile` with no photo, never a stale/foreign path.
    func testImportedTravellerProfileHasNoAvatarPath() async throws {
        let context = makeContext()
        let userId = UUID()
        let trip = makeTrip(id: "photo-trip", travellers: ["Asha"])
        let data = try TripArchiveExporter.encode(makeDocument(trips: [trip]))

        let outcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)
        guard case .success = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }

        let profile = try XCTUnwrap(try context.fetch(FetchDescriptor<TripProfile>()).first)
        XCTAssertNil(profile.avatarPath)
    }

    /// P8b (photo trip covers): same reasoning as the traveller `avatarPath`
    /// test above, for the trip's own cover — the archive format has no
    /// `cover_image_path`/`cover_credit_name`/`cover_credit_url` fields
    /// (`docs/IMPORT_FORMAT.md` §2's `cover` is a bare gradient-token
    /// string, and stays that way), so an imported trip always gets these
    /// three `nil`, same as any other brand-new `Trip` with no photo.
    func testImportedTripHasNoCoverImagePathOrCredit() async throws {
        let context = makeContext()
        let userId = UUID()
        let trip = makeTrip(id: "cover-trip")
        let data = try TripArchiveExporter.encode(makeDocument(trips: [trip]))

        let outcome = await TripArchiveImporter.importArchive(data: data, modelContext: context, syncEngine: nil, userId: userId)
        guard case .success = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }

        let storedTrip = try XCTUnwrap(try context.fetch(FetchDescriptor<Trip>()).first)
        XCTAssertNil(storedTrip.coverImagePath)
        XCTAssertNil(storedTrip.coverCreditName)
        XCTAssertNil(storedTrip.coverCreditUrl)
    }

    /// P8a: every test above builds its `ArchiveTrip`/`ArchiveDocument`
    /// fixtures through the CURRENT app's own `Codable` structs/encoder —
    /// which would trivially "support" a genuinely pre-P8a archive even if
    /// some OTHER, unrelated required key had silently been added to the
    /// decoder, since the app's own encoder would always emit whatever its
    /// own current model needs. This instead hand-authors a raw JSON string
    /// in the exact shape `docs/IMPORT_FORMAT.md` §8 documents (no avatar
    /// keys exist in that spec at all — confirmed against
    /// `Tripto/Sources/Support/TripArchive.swift`'s `ArchiveTrip`/
    /// `ArchiveItem` `CodingKeys`, neither has ever had one), fed straight
    /// into `importArchive` — the real "does a file exported by a version of
    /// this app before avatar photos existed still import cleanly" regression
    /// net that a round-trip-through-today's-own-encoder test can't be.
    func testImportOfARawPreP8aStyleArchiveJSONWithNoAvatarKeysImportsCleanly() async throws {
        let context = makeContext()
        let userId = UUID()
        let json = """
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
              "travellers": ["Asha", "Kiran"],
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
                }
              ]
            }
          ]
        }
        """

        let outcome = await TripArchiveImporter.importArchive(
            data: Data(json.utf8), modelContext: context, syncEngine: nil, userId: userId
        )
        guard case .success(let report) = outcome else {
            return XCTFail("expected success, got \(outcome)")
        }
        XCTAssertEqual(report.tripsImported, 1)
        XCTAssertEqual(report.itemsImported, 1)
        XCTAssertEqual(report.profilesImported, 2)

        let trip = try XCTUnwrap(try context.fetch(FetchDescriptor<Trip>()).first)
        XCTAssertEqual(trip.title, "Okinawa")
        // P8b: same "hand-authored legacy JSON, independent of today's own
        // encoder" regression net, extended to the trip's own cover — a
        // pre-P8b (and pre-P8a) archive has no cover-photo data of any kind.
        XCTAssertNil(trip.coverImagePath, "a pre-P8b archive has no cover photo to import")
        XCTAssertNil(trip.coverCreditName)
        XCTAssertNil(trip.coverCreditUrl)
        let profiles = try context.fetch(FetchDescriptor<TripProfile>())
        XCTAssertEqual(Set(profiles.map(\.displayName)), ["Asha", "Kiran"])
        XCTAssertTrue(profiles.allSatisfy { $0.avatarPath == nil }, "a pre-P8a archive has no avatar data to import")
    }
}
