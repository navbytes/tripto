import XCTest
@testable import Tripto

/// "Just mine" filtering (BUILD_PLAN.md §5.4, this milestone's brief §3) —
/// pure logic, no SwiftData/network (`PersonFilter`'s own doc comment).
final class PersonFilterTests: XCTestCase {
    func testEveryoneSelectionReturnsAllItemsUnfiltered() {
        let itemA = TestFixtures.makeItineraryItem(startsAt: .now)
        let itemB = TestFixtures.makeItineraryItem(startsAt: .now)
        let result = PersonFilter.filteredItems([itemA, itemB], assignees: [], selectedProfileId: nil)
        XCTAssertEqual(result.map(\.id), [itemA.id, itemB.id])
    }

    /// "default: none = everyone" (this milestone's brief) — an unassigned
    /// item is for everyone, so filtering to one specific person must not
    /// hide it.
    func testItemWithNoAssigneesStaysVisibleUnderAnyFilter() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        let someone = UUID()
        let result = PersonFilter.filteredItems([item], assignees: [], selectedProfileId: someone)
        XCTAssertEqual(result.map(\.id), [item.id])
    }

    func testItemAssignedToSomeoneElseIsExcluded() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let grandma = UUID()
        let assignees = [ItemAssignee(itemId: item.id, profileId: grandma)]
        let result = PersonFilter.filteredItems([item], assignees: assignees, selectedProfileId: meera)
        XCTAssertTrue(result.isEmpty)
    }

    func testItemAssignedToTheSelectedPersonIsIncluded() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let assignees = [ItemAssignee(itemId: item.id, profileId: meera)]
        let result = PersonFilter.filteredItems([item], assignees: assignees, selectedProfileId: meera)
        XCTAssertEqual(result.map(\.id), [item.id])
    }

    func testItemWithMultipleAssigneesIncludingSelectedPersonIsIncluded() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let grandma = UUID()
        let assignees = [
            ItemAssignee(itemId: item.id, profileId: grandma),
            ItemAssignee(itemId: item.id, profileId: meera),
        ]
        let result = PersonFilter.filteredItems([item], assignees: assignees, selectedProfileId: meera)
        XCTAssertEqual(result.map(\.id), [item.id])
    }

    func testMixedTripFiltersToOnlyRelevantAndUnassignedItems() {
        let flight = TestFixtures.makeItineraryItem(startsAt: .now) // unassigned = for everyone
        let napTime = TestFixtures.makeItineraryItem(startsAt: .now)
        let carRental = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let organizer = UUID()
        let assignees = [
            ItemAssignee(itemId: napTime.id, profileId: meera),
            ItemAssignee(itemId: carRental.id, profileId: organizer),
        ]
        let result = PersonFilter.filteredItems(
            [flight, napTime, carRental], assignees: assignees, selectedProfileId: meera
        )
        XCTAssertEqual(Set(result.map(\.id)), [flight.id, napTime.id])
    }

    // MARK: - assigneeProfileIds

    func testAssigneeProfileIdsGroupsByItemAndRespectsItemIdScope() {
        let itemInScope = UUID()
        let itemOutOfScope = UUID()
        let profile1 = UUID()
        let profile2 = UUID()
        let assignees = [
            ItemAssignee(itemId: itemInScope, profileId: profile1),
            ItemAssignee(itemId: itemInScope, profileId: profile2),
            ItemAssignee(itemId: itemOutOfScope, profileId: profile1),
        ]
        let result = PersonFilter.assigneeProfileIds(assignees, itemIds: [itemInScope])
        XCTAssertEqual(Set(result[itemInScope] ?? []), [profile1, profile2])
        XCTAssertNil(result[itemOutOfScope], "an item outside the given scope must not appear at all")
    }

    func testAssigneeProfileIdsIsEmptyWhenNothingIsAssigned() {
        XCTAssertTrue(PersonFilter.assigneeProfileIds([], itemIds: [UUID()]).isEmpty)
    }

    // MARK: - summary (honest banner breakdown)

    /// The demo case that read as a lie: everything unassigned, so nothing is
    /// "just for" the person — it's all shared.
    func testSummaryAllUnassignedAreSharedNoneJustForPerson() {
        let a = TestFixtures.makeItineraryItem(startsAt: .now)
        let b = TestFixtures.makeItineraryItem(startsAt: .now)
        let summary = PersonFilter.summary([a, b], assignees: [], selectedProfileId: UUID())
        XCTAssertEqual(summary, PersonFilter.FilterSummary(assignedToPerson: 0, shared: 2, hiddenForOthers: 0))
        XCTAssertEqual(summary.visible, 2)
        XCTAssertEqual(summary.total, 2)
    }

    func testSummarySplitsAssignedSharedAndHidden() {
        let shared = TestFixtures.makeItineraryItem(startsAt: .now)
        let mine = TestFixtures.makeItineraryItem(startsAt: .now)
        let theirs = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let grandma = UUID()
        let assignees = [
            ItemAssignee(itemId: mine.id, profileId: meera),
            ItemAssignee(itemId: theirs.id, profileId: grandma),
        ]
        let summary = PersonFilter.summary([shared, mine, theirs], assignees: assignees, selectedProfileId: meera)
        XCTAssertEqual(summary, PersonFilter.FilterSummary(assignedToPerson: 1, shared: 1, hiddenForOthers: 1))
        XCTAssertEqual(summary.visible, 2, "assigned-to-me + shared are what the filter shows")
    }

    func testSummaryItemSharedBetweenPersonAndOtherCountsAsTheirs() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        let meera = UUID()
        let grandma = UUID()
        let assignees = [
            ItemAssignee(itemId: item.id, profileId: meera),
            ItemAssignee(itemId: item.id, profileId: grandma),
        ]
        let summary = PersonFilter.summary([item], assignees: assignees, selectedProfileId: meera)
        XCTAssertEqual(summary.assignedToPerson, 1)
        XCTAssertEqual(summary.hiddenForOthers, 0)
    }

    // MARK: - hiddenDayCounts (UX audit finding 1: filtered Free-day lie)

    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, tz: String = "UTC") -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: tz)!
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components)!
    }

    func testHiddenDayCountsIsEmptyWhenNoOneIsSelected() {
        let item = TestFixtures.makeItineraryItem(startsAt: instant(2026, 5, 14, 9, 0))
        let result = PersonFilter.hiddenDayCounts(
            [item], assignees: [], selectedProfileId: nil, tripStart: DayDate(year: 2026, month: 5, day: 14)
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testHiddenDayCountsKeysByDayStringValueForAnItemAssignedToSomeoneElse() {
        let meera = UUID()
        let grandma = UUID()
        let day = DayDate(year: 2026, month: 5, day: 14)
        let item = TestFixtures.makeItineraryItem(startsAt: instant(2026, 5, 14, 9, 0))
        let assignees = [ItemAssignee(itemId: item.id, profileId: grandma)]
        let result = PersonFilter.hiddenDayCounts(
            [item], assignees: assignees, selectedProfileId: meera, tripStart: day
        )
        XCTAssertEqual(result, [day.stringValue: 1])
    }

    func testHiddenDayCountsCountsAMultiDayHotelOnEveryDayItTouches() {
        let meera = UUID()
        let grandma = UUID()
        let tripStart = DayDate(year: 2026, month: 5, day: 14)
        let hotel = TestFixtures.makeItineraryItem(
            category: .hotel,
            startsAt: instant(2026, 5, 14, 15, 0),
            endsAt: instant(2026, 5, 17, 11, 0)
        )
        let assignees = [ItemAssignee(itemId: hotel.id, profileId: grandma)]
        let result = PersonFilter.hiddenDayCounts(
            [hotel], assignees: assignees, selectedProfileId: meera, tripStart: tripStart
        )
        XCTAssertEqual(result, [
            DayDate(year: 2026, month: 5, day: 14).stringValue: 1, // check-in
            DayDate(year: 2026, month: 5, day: 15).stringValue: 1, // staying
            DayDate(year: 2026, month: 5, day: 16).stringValue: 1, // staying
            DayDate(year: 2026, month: 5, day: 17).stringValue: 1, // check-out
        ])
    }

    func testHiddenDayCountsOnlyCountsTheHiddenItemWhenADayMixesVisibleAndHidden() {
        let meera = UUID()
        let grandma = UUID()
        let day = DayDate(year: 2026, month: 5, day: 14)
        let shared = TestFixtures.makeItineraryItem(startsAt: instant(2026, 5, 14, 8, 0)) // unassigned = visible
        let theirs = TestFixtures.makeItineraryItem(startsAt: instant(2026, 5, 14, 9, 0))
        let assignees = [ItemAssignee(itemId: theirs.id, profileId: grandma)]
        let result = PersonFilter.hiddenDayCounts(
            [shared, theirs], assignees: assignees, selectedProfileId: meera, tripStart: day
        )
        XCTAssertEqual(result, [day.stringValue: 1])
    }

    func testHiddenDayCountsExcludesItemsAssignedToTheSelectedPerson() {
        let meera = UUID()
        let day = DayDate(year: 2026, month: 5, day: 14)
        let item = TestFixtures.makeItineraryItem(startsAt: instant(2026, 5, 14, 9, 0))
        let assignees = [ItemAssignee(itemId: item.id, profileId: meera)]
        let result = PersonFilter.hiddenDayCounts(
            [item], assignees: assignees, selectedProfileId: meera, tripStart: day
        )
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - reconciledSelection (finding 5: stale "Just mine" filter)

    func testReconciledSelectionNilStaysNil() {
        XCTAssertNil(PersonFilter.reconciledSelection(nil, profileIds: [UUID()]))
    }

    func testReconciledSelectionKeptWhenPresentInProfileIds() {
        let meera = UUID()
        let result = PersonFilter.reconciledSelection(meera, profileIds: [meera, UUID()])
        XCTAssertEqual(result, meera)
    }

    func testReconciledSelectionResetsWhenProfileRemoved() {
        let meera = UUID()
        let result = PersonFilter.reconciledSelection(meera, profileIds: [UUID()])
        XCTAssertNil(result)
    }

    func testReconciledSelectionResetsWhenProfileIdsEmpty() {
        let meera = UUID()
        XCTAssertNil(PersonFilter.reconciledSelection(meera, profileIds: []))
    }
}
