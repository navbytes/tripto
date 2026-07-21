import XCTest
@testable import Tripto

/// `TripPromptContext.render` — the pure trip-context serializer behind
/// both on-device AI garnishes (PLAN.md ai-garnish: "Catch me up",
/// packing suggestions). Hermetic by construction: every date below is
/// built against a fixed UTC calendar (same recipe `ShareSummaryTests`/
/// `TripDateRangeFormatTests` already use), and `ShareSummary.text(for:)`'s
/// own tz-correctness is proven once, in `ShareSummaryTests` — this file
/// only proves `render` delegates to it rather than re-deriving date math
/// of its own. `Platform/OnDeviceExtractor.swift`'s own house rule ("do
/// not unit-test actual model calls") is why nothing here touches
/// FoundationModels at all.
final class TripPromptContextTests: XCTestCase {
    private func utcInstant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return utc.date(from: components)!
    }

    private func makeTrip(title: String = "Kyoto Family Trip", destination: String = "Kyoto, Japan") -> Trip {
        TestFixtures.makeTrip(
            title: title, destination: destination,
            startDate: utcInstant(2027, 3, 14), endDate: utcInstant(2027, 3, 20)
        )
    }

    // MARK: - Title/destination/travelers

    func testIncludesTripTitleDestinationAndTravelerNames() {
        let trip = makeTrip()
        let context = TripPromptContext.render(trip: trip, memberNames: ["Naveen", "Meera"], items: [])

        XCTAssertTrue(context.contains("Kyoto Family Trip"))
        XCTAssertTrue(context.contains("Kyoto, Japan"))
        XCTAssertTrue(context.contains("Naveen, Meera"))
    }

    func testOmitsTravelersLineWhenNoMemberNames() {
        let context = TripPromptContext.render(trip: makeTrip(), memberNames: [], items: [])
        XCTAssertFalse(context.contains("Travelers:"))
    }

    // MARK: - Itinerary: tz-correct by delegation, capped at itemBudget

    /// Delegates to `ShareSummary.text(for:)` verbatim — proof this is
    /// tz-correct BY CONSTRUCTION (that function's own tz-correctness is
    /// covered by `ShareSummaryTests`), not re-derived here. `Asia/Tokyo`
    /// is deliberately neither UTC nor whatever zone happens to run this
    /// test, so a hidden `.current`/`TimeZone.current` dependency would
    /// show up as a mismatch.
    func testItineraryLineIsTzCorrectByDelegatingToShareSummary() {
        let trip = makeTrip()
        let item = TestFixtures.makeItineraryItem(
            tripId: trip.id, category: .activity, title: "Fushimi Inari hike",
            startsAt: utcInstant(2027, 3, 15, 1, 0), tz: "Asia/Tokyo", locationName: "Fushimi Inari-taisha"
        )

        let context = TripPromptContext.render(trip: trip, memberNames: [], items: [item])

        XCTAssertTrue(context.contains("- \(ShareSummary.text(for: item))"))
    }

    func testEmptyItineraryReadsAsNothingPlannedRatherThanABlankSection() {
        let context = TripPromptContext.render(trip: makeTrip(), memberNames: [], items: [])
        XCTAssertTrue(context.contains("nothing planned yet"))
    }

    /// PLAN.md: "Cap serialized items (~40) mirroring the
    /// `importContextBudget` precedent" — 45 items in, only the first 40
    /// (array order, same as `TripView.items`' own start-sort) survive.
    func testItineraryLinesAreCappedAtItemBudget() {
        XCTAssertEqual(TripPromptContext.itemBudget, 40)
        let trip = makeTrip()
        let items = (1...45).map { index in
            TestFixtures.makeItineraryItem(
                tripId: trip.id, category: .activity, title: String(format: "Item %02d", index),
                startsAt: utcInstant(2027, 3, 14).addingTimeInterval(TimeInterval(index) * 3600), tz: "UTC"
            )
        }

        let context = TripPromptContext.render(trip: trip, memberNames: [], items: items)

        XCTAssertTrue(context.contains("Item 40"), "the 40th item should be included")
        XCTAssertFalse(context.contains("Item 41"), "the 41st item should be dropped by the cap")
        XCTAssertFalse(context.contains("Item 45"), "the 45th item should be dropped by the cap")
    }

    // MARK: - existingPackingLabels: nil vs empty vs populated

    func testExistingPackingLabelsSectionOmittedWhenNil() {
        let context = TripPromptContext.render(trip: makeTrip(), memberNames: [], items: [], existingPackingLabels: nil)
        XCTAssertFalse(context.contains("Packing list"))
    }

    func testExistingPackingLabelsSectionShowsEmptyMarkerForAnEmptyArray() {
        let context = TripPromptContext.render(trip: makeTrip(), memberNames: [], items: [], existingPackingLabels: [])
        XCTAssertTrue(context.contains("Packing list so far: (empty)"))
    }

    func testExistingPackingLabelsAreJoinedWhenPresent() {
        let context = TripPromptContext.render(
            trip: makeTrip(), memberNames: [], items: [], existingPackingLabels: ["Passports", "Sunscreen"]
        )
        XCTAssertTrue(context.contains("Passports, Sunscreen"))
    }
}
