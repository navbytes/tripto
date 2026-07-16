import SwiftData
import XCTest
@testable import Tripto

/// PLAN-signature-layer.md §D6 (W2-A): covers every frozen contract this
/// package lands — `TripSnapshot`'s file round-trip, `SyncStore.
/// buildSnapshot()`'s focus-trip selection/caps (the actual branch/loop
/// logic), `DeepLink.tripId(from:)`, `AppRouter.openTrip(id:)`, and
/// `SnapshotWriter.clear()`'s "always fires `onWrite(nil)`" guarantee.
/// `SnapshotWriter.notifyDataChanged()`'s debounce timing itself is left
/// to the live verify drill (same convention as `SyncEngine.schedulePush()`,
/// which has no dedicated timing test either) rather than a sleep-based
/// unit test.
final class TripSnapshotTests: XCTestCase {
    // MARK: - TripSnapshot file round-trip

    func testSaveThenLoadRoundTripsExactly() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        let tripId = UUID()
        let itemId = UUID()
        let snapshot = TripSnapshot(
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            trips: [SnapshotTrip(
                id: tripId, title: "Lisbon", coverGradient: "dusk",
                startDate: Date(timeIntervalSince1970: 1_800_000_000),
                endDate: Date(timeIntervalSince1970: 1_800_600_000),
                destination: "Lisbon, Portugal"
            )],
            focusTripItems: [SnapshotItem(
                id: itemId, tripId: tripId, title: "TAP TP1234", category: .flight,
                startsAt: Date(timeIntervalSince1970: 1_800_100_000), endsAt: nil, tz: "America/New_York",
                fromIATA: "JFK", toIATA: "LIS", flightNo: "TP1234", locationName: "JFK"
            )]
        )

        try snapshot.save(to: dir)
        let loaded = TripSnapshot.load(from: dir)

        XCTAssertEqual(loaded, snapshot)
    }

    func testLoadReturnsNilWhenNoFileExists() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(TripSnapshot.load(from: dir))
    }

    func testLoadReturnsNilForAMismatchedVersion() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

        var snapshot = TripSnapshot(generatedAt: .now, trips: [], focusTripItems: [])
        snapshot.version = TripSnapshot.currentVersion + 1
        try snapshot.save(to: dir)

        XCTAssertNil(TripSnapshot.load(from: dir), "a version this reader doesn't know must read as absent, not crash")
    }

    func testSaveThrowsWithNoContainer() {
        let snapshot = TripSnapshot(generatedAt: .now, trips: [], focusTripItems: [])
        XCTAssertThrowsError(try snapshot.save(to: nil))
    }

    private func makeScratchDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - DeepLink.tripId(from:) — widget/Spotlight/Siri open link

    func testTripIdParsesCustomScheme() {
        let id = UUID()
        let url = URL(string: "tripto://trip/\(id.uuidString)")!
        XCTAssertEqual(DeepLink.tripId(from: url), id)
    }

    func testTripIdReturnsNilForWrongHost() {
        XCTAssertNil(DeepLink.tripId(from: URL(string: "tripto://join/\(UUID().uuidString)")!))
    }

    func testTripIdReturnsNilForNonUUIDSegment() {
        XCTAssertNil(DeepLink.tripId(from: URL(string: "tripto://trip/not-a-uuid")!))
    }

    func testTripIdReturnsNilForUniversalLinkForm() {
        // No web route exists for this shape — only the custom scheme.
        XCTAssertNil(DeepLink.tripId(from: URL(string: "https://tripto.navbytes.io/trip/\(UUID().uuidString)")!))
    }

    func testTripIdReturnsNilForExtraTrailingSegments() {
        XCTAssertNil(DeepLink.tripId(from: URL(string: "tripto://trip/\(UUID().uuidString)/extra")!))
    }

    // MARK: - AppRouter.openTrip(id:)

    @MainActor
    func testOpenTripSetsTripToOpen() {
        let router = AppRouter()
        let id = UUID()
        XCTAssertNil(router.tripToOpen)
        router.openTrip(id: id)
        XCTAssertEqual(router.tripToOpen, id)
    }

    // MARK: - SyncStore.buildSnapshot()

    /// Fixed reference instant (noon UTC — clear of any calendar-day
    /// boundary in any real device time zone) + a UTC calendar for the
    /// day-offset math below, mirroring `DateBucketingTests`' own "never
    /// `Calendar.current`" discipline so a midnight/zone-boundary CI run
    /// can't flake the tightest (same-day) case below.
    /// `buildSnapshot`/`Trip.bucket` still default to `Calendar.current` for
    /// the actual bucket comparison (no test seam to override that), but
    /// pinning `now` removes the one real variable: which live moment the
    /// suite happens to run at.
    private let referenceNow = Date(timeIntervalSince1970: 1_800_014_400)
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    func testBuildSnapshotExcludesPastTripsAndCapsAtSix() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let now = referenceNow
        let calendar = utc

        var dtos: [TripDTO] = []
        let pastId = UUID()
        dtos.append(TestFixtures.makeTripDTO(
            id: pastId,
            startDate: dayDate(offsetDays: -20, from: now, calendar),
            endDate: dayDate(offsetDays: -15, from: now, calendar)
        ))
        // 7 upcoming trips (one more than the cap) so both the past
        // exclusion and the max-6 cap are exercised in one pass.
        var upcomingIds: [UUID] = []
        for offset in 1...7 {
            let id = UUID()
            upcomingIds.append(id)
            dtos.append(TestFixtures.makeTripDTO(
                id: id,
                startDate: dayDate(offsetDays: offset, from: now, calendar),
                endDate: dayDate(offsetDays: offset + 2, from: now, calendar)
            ))
        }
        try await store.applyTrips(dtos)

        let snapshot = try await store.buildSnapshot(now: now)

        XCTAssertEqual(snapshot.trips.count, 6, "max 6 trips even with 7 eligible")
        XCTAssertFalse(snapshot.trips.contains { $0.id == pastId }, "a trip that already ended must never appear")
        XCTAssertEqual(snapshot.trips.map(\.id), Array(upcomingIds.prefix(6)), "soonest-starting first")
    }

    func testBuildSnapshotFocusItemsBelongOnlyToTheInProgressTrip() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let now = referenceNow
        let calendar = utc

        let inProgressId = UUID()
        let upcomingId = UUID()
        try await store.applyTrips([
            TestFixtures.makeTripDTO(
                id: inProgressId,
                startDate: dayDate(offsetDays: -1, from: now, calendar),
                endDate: dayDate(offsetDays: 3, from: now, calendar)
            ),
            TestFixtures.makeTripDTO(
                id: upcomingId,
                startDate: dayDate(offsetDays: 5, from: now, calendar),
                endDate: dayDate(offsetDays: 8, from: now, calendar)
            )
        ])

        let inProgressItemId = UUID()
        try await store.applyItineraryItems(
            [makeFlightDTO(id: inProgressItemId, tripId: inProgressId, startsAt: now)], tripId: inProgressId
        )
        // An item on the other (non-focus) trip must never leak into
        // `focusTripItems`.
        try await store.applyItineraryItems(
            [makeFlightDTO(id: UUID(), tripId: upcomingId, startsAt: now.addingTimeInterval(86_400 * 5))],
            tripId: upcomingId
        )

        let snapshot = try await store.buildSnapshot(now: now)

        XCTAssertEqual(snapshot.focusTripItems.map(\.id), [inProgressItemId])
        XCTAssertEqual(snapshot.focusTripItems.first?.tripId, inProgressId)
    }

    /// Wave-2 review should-fix: `suggested` (unreviewed import) items must
    /// never reach the snapshot — its consumers (Today widget, Siri next-up,
    /// lock-screen Live Activity) are more public than the in-app tabs,
    /// which already filter to confirmed at the query (TripView).
    func testBuildSnapshotExcludesSuggestedItems() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let now = referenceNow
        let calendar = utc

        let tripId = UUID()
        try await store.applyTrips([
            TestFixtures.makeTripDTO(
                id: tripId,
                startDate: dayDate(offsetDays: -1, from: now, calendar),
                endDate: dayDate(offsetDays: 3, from: now, calendar)
            )
        ])

        let confirmedId = UUID()
        try await store.applyItineraryItems([
            makeFlightDTO(id: confirmedId, tripId: tripId, startsAt: now),
            makeFlightDTO(id: UUID(), tripId: tripId, startsAt: now.addingTimeInterval(3_600), status: .suggested)
        ], tripId: tripId)

        let snapshot = try await store.buildSnapshot(now: now)

        XCTAssertEqual(snapshot.focusTripItems.map(\.id), [confirmedId])
    }

    func testBuildSnapshotFocusesSoonestUpcomingWhenNoneInProgress() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let now = referenceNow
        let calendar = utc

        let soonerId = UUID()
        let laterId = UUID()
        try await store.applyTrips([
            TestFixtures.makeTripDTO(
                id: laterId,
                startDate: dayDate(offsetDays: 10, from: now, calendar),
                endDate: dayDate(offsetDays: 12, from: now, calendar)
            ),
            TestFixtures.makeTripDTO(
                id: soonerId,
                startDate: dayDate(offsetDays: 2, from: now, calendar),
                endDate: dayDate(offsetDays: 4, from: now, calendar)
            )
        ])

        let snapshot = try await store.buildSnapshot(now: now)

        XCTAssertEqual(snapshot.trips.first?.id, soonerId, "soonest upcoming sorts first with nothing in progress")
        XCTAssertEqual(snapshot.focusTripItems, [], "the focus trip has no seeded items")
    }

    func testBuildSnapshotCapsFocusItemsAtOneHundredAndMapsFlightFields() async throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let now = referenceNow
        let calendar = utc

        let tripId = UUID()
        try await store.applyTrips([TestFixtures.makeTripDTO(
            id: tripId, startDate: dayDate(offsetDays: 0, from: now, calendar), endDate: dayDate(offsetDays: 1, from: now, calendar)
        )])

        let dtos = (0..<110).map { offset in
            makeFlightDTO(id: UUID(), tripId: tripId, startsAt: now.addingTimeInterval(TimeInterval(offset) * 60))
        }
        try await store.applyItineraryItems(dtos, tripId: tripId)

        let snapshot = try await store.buildSnapshot(now: now)
        XCTAssertEqual(snapshot.focusTripItems.count, 100, "max 100 items")

        let firstItem = snapshot.focusTripItems.first
        XCTAssertEqual(firstItem?.category, .flight)
        XCTAssertEqual(firstItem?.fromIATA, "JFK")
        XCTAssertEqual(firstItem?.toIATA, "LIS")
        XCTAssertEqual(firstItem?.flightNo, "TP1234")
    }

    /// `confirmation`/`notes` are set on the DTO (a booking code, a private
    /// note) but `SnapshotItem` has no field either could land in —
    /// sanitization by construction, not by filtering (BUILD_PLAN §7.5).
    private func makeFlightDTO(
        id: UUID, tripId: UUID, startsAt: Date, status: ItemStatus = .confirmed
    ) -> ItineraryItemDTO {
        var details = ItemDetails.empty
        details.fromIATA = "JFK"
        details.toIATA = "LIS"
        details.flightNo = "TP1234"
        return ItineraryItemDTO(
            id: id, tripId: tripId, category: ItemCategory.flight.rawValue, title: "TAP TP1234",
            startsAt: startsAt, endsAt: nil, tz: "America/New_York", locationName: "JFK",
            locationLat: nil, locationLng: nil, confirmation: "QK7P2M", notes: "aisle seat requested",
            details: details.json, status: status.rawValue,
            createdBy: UUID(), createdAt: .now, updatedAt: .now, updatedBy: nil
        )
    }

    private func dayDate(offsetDays: Int, from now: Date, _ calendar: Calendar) -> DayDate {
        DayDate.from(calendar.date(byAdding: .day, value: offsetDays, to: now) ?? now, calendar: calendar)
    }

    // MARK: - SnapshotWriter

    /// The one frozen guarantee worth pinning at the unit level: `clear()`
    /// always calls `onWrite(nil)`, even with no App Group container to
    /// actually delete a file from (this test's own environment —
    /// `TriptoTests` carries no app-group entitlement, same as an unsigned
    /// build). `notifyDataChanged()`'s debounced write path can't succeed
    /// here for the same reason (`TripSnapshot.save()` needs the real
    /// container) — that path is exercised live instead (see file doc
    /// comment).
    func testClearAlwaysFiresOnWriteWithNil() async {
        let container = AppSchema.makeContainer(inMemory: true)
        let store = SyncStore(modelContainer: container)
        let writer = SnapshotWriter(store: store)

        let box = SnapshotResultBox()
        await writer.setOnWrite { box.received = $0 }
        await writer.clear()

        XCTAssertEqual(box.received, .some(nil), "clear() must always fire onWrite(nil)")
    }
}

/// Plain reference box so the `onWrite` closure above can report back to
/// the test without an `XCTestExpectation` — `clear()` invokes `onWrite`
/// synchronously within the actor call the test already awaits, so the
/// value is set by the time `await writer.clear()` returns.
private final class SnapshotResultBox: @unchecked Sendable {
    var received: TripSnapshot??
}
