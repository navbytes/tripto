import XCTest
@testable import Tripto

/// "Add to calendar" (BUILD_PLAN.md §4.4) — `CalendarEventDraft`/
/// `CalendarEventBuilder` are deliberately Foundation-only so this is
/// testable with no calendar permission and no `EKEventStore` involved (see
/// that type's own doc comment); `BookingDetailView` is the only place that
/// actually touches EventKit.
final class CalendarEventDraftTests: XCTestCase {
    /// This milestone's brief, verbatim: "EKEvent building uses item.tz" —
    /// never the arrival zone for a flight, never the device's zone.
    func testDraftUsesTheItemsOwnTimeZoneNeverTheArrivalZone() {
        var details = ItemDetails.empty
        details.arrivalTz = "Europe/Lisbon"
        let flight = TestFixtures.makeItineraryItem(
            category: .flight, title: "TAP TP1234",
            startsAt: Date(timeIntervalSince1970: 1_000_000),
            endsAt: Date(timeIntervalSince1970: 1_000_000 + 3600),
            tz: "America/New_York", details: details
        )

        let draft = CalendarEventBuilder.draft(for: flight)

        XCTAssertEqual(draft.timeZone.identifier, "America/New_York")
        XCTAssertNotEqual(draft.timeZone.identifier, "Europe/Lisbon")
        XCTAssertEqual(draft.startDate, flight.startsAt)
        XCTAssertEqual(draft.endDate, flight.endsAt)
    }

    /// This milestone's brief: "notes WITHOUT confirmation code" — Calendar
    /// is a different trust boundary than the app (§7.5's sanitization
    /// spirit extended to a third-party surface).
    func testDraftNotesNeverIncludeTheConfirmationCode() {
        let item = TestFixtures.makeItineraryItem(
            category: .hotel, startsAt: .now, tz: "Europe/Lisbon", confirmation: "HTL-88213"
        )
        item.notes = "Late check-in requested, arriving after 22:00."

        let draft = CalendarEventBuilder.draft(for: item)

        XCTAssertEqual(draft.notes, "Late check-in requested, arriving after 22:00.")
        XCTAssertFalse((draft.notes ?? "").contains("HTL-88213"))
    }

    func testDraftFillsAnHourWhenThereIsNoEndsAt() {
        let activity = TestFixtures.makeItineraryItem(category: .activity, startsAt: .now, endsAt: nil, tz: "Europe/Lisbon")
        let draft = CalendarEventBuilder.draft(for: activity)
        XCTAssertEqual(draft.endDate.timeIntervalSince(draft.startDate), 3600)
    }

    func testDraftOmitsAnEmptyLocationName() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now, tz: "UTC", locationName: "")
        XCTAssertNil(CalendarEventBuilder.draft(for: item).locationName)
    }

    func testDraftCarriesANonEmptyLocationName() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now, tz: "UTC", locationName: "Belém, Lisbon")
        XCTAssertEqual(CalendarEventBuilder.draft(for: item).locationName, "Belém, Lisbon")
    }
}
