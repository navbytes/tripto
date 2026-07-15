import SwiftData
import XCTest
@testable import Tripto

/// `TripArchiveExporter.composeDocument` (docs/IMPORT_FORMAT.md §7) — pure,
/// plain `Trip`/`ItineraryItem`/`TripProfile` arrays in, `ArchiveDocument`
/// out, so this needs no `ModelContainer` (same "build the model directly"
/// convention `TripDuplicationTests`/`TestFixtures` already use). One
/// exception: `testExportRunsEndToEndWithModelsAttachedToAnInMemoryContainer`
/// below exercises the real async `export(trips:items:profiles:)` entry
/// point with attached `@Model` instances (D3/N1 — `composeDocument` reads
/// `@Model` properties and must run on the main actor; unattached fixtures
/// can't surface that, since an unattached model just reads plain memory).
final class TripArchiveExporterTests: XCTestCase {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    func testComposeDocumentEmitsTheRowUUIDAsTheTripId() {
        let tripId = UUID()
        let trip = TestFixtures.makeTrip(id: tripId, startDate: .now, endDate: .now)
        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [], profiles: [])
        XCTAssertEqual(document.trips.first?.id, tripId.uuidString)
        XCTAssertEqual(document.format, TripArchiveFormat.identifier)
        XCTAssertEqual(document.version, TripArchiveFormat.supportedVersion)
    }

    func testStatusIsCompletedWhenTheTripEndedBeforeToday() {
        let today = utc.date(from: DateComponents(year: 2026, month: 6, day: 1))!
        let trip = TestFixtures.makeTrip(
            startDate: utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!,
            endDate: utc.date(from: DateComponents(year: 2026, month: 1, day: 5))!
        )
        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [], profiles: [], today: today, calendar: utc)
        XCTAssertEqual(document.trips.first?.status, "completed")
    }

    func testStatusIsUpcomingWhenTheTripHasNotEndedYet() {
        let today = utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let trip = TestFixtures.makeTrip(
            startDate: utc.date(from: DateComponents(year: 2026, month: 6, day: 1))!,
            endDate: utc.date(from: DateComponents(year: 2026, month: 6, day: 5))!
        )
        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [], profiles: [], today: today, calendar: utc)
        XCTAssertEqual(document.trips.first?.status, "upcoming")
    }

    /// §7 only defines two states; a trip currently in progress (start <=
    /// today <= end) is "upcoming", not a third value.
    func testStatusIsUpcomingForATripCurrentlyInProgress() {
        let today = utc.date(from: DateComponents(year: 2026, month: 6, day: 3))!
        let trip = TestFixtures.makeTrip(
            startDate: utc.date(from: DateComponents(year: 2026, month: 6, day: 1))!,
            endDate: utc.date(from: DateComponents(year: 2026, month: 6, day: 5))!
        )
        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [], profiles: [], today: today, calendar: utc)
        XCTAssertEqual(document.trips.first?.status, "upcoming")
    }

    func testTravellersOnlyIncludeUnlinkedProfilesNotTheOrganizersOwnAccount() {
        let tripId = UUID()
        let trip = TestFixtures.makeTrip(id: tripId, startDate: .now, endDate: .now)
        let grandma = TripProfile(id: UUID(), tripId: tripId, displayName: "Grandma", avatarColor: "sky", linkedUserId: nil, createdAt: .now)
        let organizer = TripProfile(id: UUID(), tripId: tripId, displayName: "Organizer", avatarColor: "amber", linkedUserId: UUID(), createdAt: .now)
        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [], profiles: [grandma, organizer])
        XCTAssertEqual(document.trips.first?.travellers, ["Grandma"])
    }

    func testItemsAndProfilesAreScopedToTheirOwnTripOnly() {
        let tripA = UUID()
        let tripB = UUID()
        let tripAModel = TestFixtures.makeTrip(id: tripA, title: "A", startDate: .now, endDate: .now)
        let tripBModel = TestFixtures.makeTrip(id: tripB, title: "B", startDate: .now, endDate: .now)
        let itemA = TestFixtures.makeItineraryItem(tripId: tripA, startsAt: .now)
        let itemB = TestFixtures.makeItineraryItem(tripId: tripB, startsAt: .now)
        let profileA = TripProfile(id: UUID(), tripId: tripA, displayName: "A-person", avatarColor: "sky", linkedUserId: nil, createdAt: .now)

        let document = TripArchiveExporter.composeDocument(trips: [tripAModel, tripBModel], items: [itemA, itemB], profiles: [profileA])

        XCTAssertEqual(document.trips.first { $0.title == "A" }?.items.count, 1)
        XCTAssertEqual(document.trips.first { $0.title == "B" }?.items.count, 1)
        XCTAssertEqual(document.trips.first { $0.title == "A" }?.travellers, ["A-person"])
        XCTAssertEqual(document.trips.first { $0.title == "B" }?.travellers, [])
    }

    /// §2/§7: trips have no `notes` column in this app — never emitted,
    /// documented as a known export limitation.
    func testTripLevelNotesAreNeverEmitted() {
        let trip = TestFixtures.makeTrip(startDate: .now, endDate: .now)
        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [], profiles: [])
        XCTAssertNil(document.trips.first?.notes)
    }

    func testItemDetailFieldsRoundTripOntoTheArchiveItem() throws {
        let tripId = UUID()
        let item = TestFixtures.makeItineraryItem(
            tripId: tripId, category: .flight, title: "TAP TP1234", startsAt: .now, tz: "America/New_York",
            locationName: "JFK", confirmation: "ABC123",
            details: ItemDetails(airline: "TAP", flightNo: "TP1234", fromIATA: "JFK", toIATA: "LIS", seat: "14A", arrivalTz: "Europe/Lisbon")
        )
        let trip = TestFixtures.makeTrip(id: tripId, startDate: .now, endDate: .now)
        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [item], profiles: [])
        let archiveItem = try XCTUnwrap(document.trips.first?.items.first)

        XCTAssertEqual(archiveItem.category, "flight")
        XCTAssertEqual(archiveItem.airline, "TAP")
        XCTAssertEqual(archiveItem.flightNo, "TP1234")
        XCTAssertEqual(archiveItem.fromIATA, "JFK")
        XCTAssertEqual(archiveItem.toIATA, "LIS")
        XCTAssertEqual(archiveItem.seat, "14A")
        XCTAssertEqual(archiveItem.arrivalTz, "Europe/Lisbon")
        XCTAssertEqual(archiveItem.confirmation, "ABC123")
        XCTAssertEqual(archiveItem.tz, "America/New_York")
    }

    func testEncodedDocumentIsDecodableByTheImportSideMapper() throws {
        let trip = TestFixtures.makeTrip(startDate: .now, endDate: .now)
        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [], profiles: [])
        let data = try TripArchiveExporter.encode(document)
        let decoded = try TripArchiveMapper.decode(data)
        XCTAssertEqual(decoded.trips.count, 1)
    }

    func testWriteTempFileUsesTheDocumentedFilenameConventionAndContents() throws {
        let today = utc.date(from: DateComponents(year: 2026, month: 7, day: 13))!
        let url = try TripArchiveExporter.writeTempFile(Data("{}".utf8), today: today, calendar: utc)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(url.lastPathComponent, "tripto-archive-2026-07-13.json")
        let written = try Data(contentsOf: url)
        XCTAssertEqual(String(data: written, encoding: .utf8), "{}")
    }

    /// D3/N1: the real async entry point, end to end, with rows actually
    /// attached to an in-memory `ModelContainer` (not `TestFixtures`'
    /// unattached-model style the rest of this file uses) — proves
    /// `export`'s actor structure runs cleanly under the test runner, same
    /// shape as `TripArchiveImporterTests`.
    @MainActor
    func testExportRunsEndToEndWithModelsAttachedToAnInMemoryContainer() async throws {
        let context = ModelContext(AppSchema.makeContainer(inMemory: true))
        let tripId = UUID()
        let now = Date()
        let trip = Trip(
            id: tripId, title: "Kyoto", destination: "Kyoto, Japan", countryCode: "JP",
            startDate: now, endDate: now.addingTimeInterval(4 * 86_400), coverGradient: "dusk",
            tripTypeRaw: TripType.family.rawValue, createdBy: UUID(), createdAt: now, updatedAt: now, updatedBy: nil
        )
        let item = ItineraryItem(
            id: UUID(), tripId: tripId, categoryRaw: ItemCategory.activity.rawValue, title: "Fushimi Inari",
            startsAt: now, endsAt: nil, tz: "Asia/Tokyo", locationName: "Kyoto",
            locationLat: nil, locationLng: nil, confirmation: nil, notes: nil,
            detailsJSON: "{}", statusRaw: ItemStatus.confirmed.rawValue, createdBy: UUID(),
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        let profile = TripProfile(id: UUID(), tripId: tripId, displayName: "Grandma", avatarColor: "sky", linkedUserId: nil, createdAt: now)
        context.insert(trip)
        context.insert(item)
        context.insert(profile)
        try context.save()

        let fetchedTrips = try context.fetch(FetchDescriptor<Trip>())
        let fetchedItems = try context.fetch(FetchDescriptor<ItineraryItem>())
        let fetchedProfiles = try context.fetch(FetchDescriptor<TripProfile>())

        let url = try await TripArchiveExporter.export(trips: fetchedTrips, items: fetchedItems, profiles: fetchedProfiles)
        defer { try? FileManager.default.removeItem(at: url) }

        let decoded = try TripArchiveMapper.decode(try Data(contentsOf: url))
        XCTAssertEqual(decoded.trips.count, 1)
        XCTAssertEqual(decoded.trips.first?.title, "Kyoto")
        XCTAssertEqual(decoded.trips.first?.items.count, 1)
        XCTAssertEqual(decoded.trips.first?.travellers, ["Grandma"])
    }

    /// P8a (avatar photos): `travellers` stays a bare `[String]` of display
    /// names (`docs/IMPORT_FORMAT.md` §2) — a traveller's `avatarPath` is a
    /// storage path meaningless outside this project, so it must never leak
    /// into the portable archive format.
    func testTravellerAvatarPathNeverLeaksIntoTheExportedArchive() throws {
        let tripId = UUID()
        let trip = TestFixtures.makeTrip(id: tripId, startDate: .now, endDate: .now)
        let grandma = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Grandma", avatarColor: "sky",
            avatarPath: "\(UUID().uuidString)/photo.jpg", linkedUserId: nil, createdAt: .now
        )

        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [], profiles: [grandma])
        XCTAssertEqual(document.trips.first?.travellers, ["Grandma"])

        let encoded = try TripArchiveExporter.encode(document)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("photo.jpg"))
        XCTAssertFalse(json.lowercased().contains("avatar_path"))
    }

    /// P8b (photo trip covers): same reasoning as the traveller `avatarPath`
    /// test above, for the trip's OWN cover photo/credit this time —
    /// `cover_image_path` is a storage path meaningless outside this
    /// project, and `cover_credit_name`/`cover_credit_url` name a specific
    /// upload this app made; none of the three belong in a portable,
    /// cross-app migration format any LLM can generate
    /// (`docs/IMPORT_FORMAT.md`'s own "frozen v1" contract). `ArchiveTrip`'s
    /// `cover` key stays exactly what it was pre-P8b: the gradient token
    /// only.
    func testTripCoverPhotoAndCreditNeverLeakIntoTheExportedArchive() throws {
        let trip = TestFixtures.makeTrip(startDate: .now, endDate: .now)
        trip.coverImagePath = "\(UUID().uuidString)/cover-photo.jpg"
        trip.coverCreditName = "Priya Sharma"
        trip.coverCreditUrl = "https://www.pexels.com/photo/12345"

        let document = TripArchiveExporter.composeDocument(trips: [trip], items: [], profiles: [])
        XCTAssertEqual(document.trips.first?.cover, "dusk")

        let encoded = try TripArchiveExporter.encode(document)
        let json = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(json.contains("cover-photo.jpg"))
        XCTAssertFalse(json.contains("Priya Sharma"))
        XCTAssertFalse(json.contains("pexels.com"))
        XCTAssertFalse(json.lowercased().contains("cover_image_path"))
        XCTAssertFalse(json.lowercased().contains("cover_credit"))
    }
}
