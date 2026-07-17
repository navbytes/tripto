import XCTest
@testable import Tripto

/// DBG-bookings: pins `ItineraryItem.isBooking`, the single definition of
/// "what is a booking" that replaced the two definitions that never met (the
/// import pipeline's `status` lifecycle and `BookingsTabView`'s old bare
/// `confirmation != ""` check — see the handoff doc for the full trace). No
/// prior test asserted Bookings-tab membership against anything; this file
/// closes that gap.
final class BookingMembershipTests: XCTestCase {
    // MARK: - flight/hotel/transport are always bookings, code or not

    func testFlightIsABookingWithAConfirmationCode() {
        let item = TestFixtures.makeItineraryItem(category: .flight, startsAt: .now, confirmation: "QK7P2M")
        XCTAssertTrue(item.isBooking)
    }

    func testFlightIsABookingWithNoConfirmationCode() {
        let item = TestFixtures.makeItineraryItem(category: .flight, startsAt: .now, confirmation: nil)
        XCTAssertTrue(item.isBooking, "a confirmed flight is a booking even with no code on file")
    }

    func testHotelIsABookingWithAConfirmationCode() {
        let item = TestFixtures.makeItineraryItem(category: .hotel, startsAt: .now, confirmation: "HTL-88213")
        XCTAssertTrue(item.isBooking)
    }

    /// The exact "Memmo Alfama" shape from the sqlite evidence: a confirmed
    /// hotel with `confirmation: nil` that the old `confirmation != ""`
    /// predicate silently dropped from Bookings.
    func testHotelIsABookingWithNoConfirmationCode() {
        let item = TestFixtures.makeItineraryItem(category: .hotel, title: "Memmo Alfama", startsAt: .now, confirmation: nil)
        XCTAssertTrue(item.isBooking, "a confirmed hotel is a booking even with no code on file")
    }

    func testTransportIsABookingWithAConfirmationCode() {
        let item = TestFixtures.makeItineraryItem(category: .transport, startsAt: .now, confirmation: "HZ-40192")
        XCTAssertTrue(item.isBooking)
    }

    func testTransportIsABookingWithNoConfirmationCode() {
        let item = TestFixtures.makeItineraryItem(category: .transport, startsAt: .now, confirmation: nil)
        XCTAssertTrue(item.isBooking, "a confirmed rental/transfer is a booking even with no code on file")
    }

    // MARK: - activity/food need a reservation marker; a plain one isn't a booking

    func testActivityWithNoMarkerIsNotABooking() {
        let item = TestFixtures.makeItineraryItem(category: .activity, startsAt: .now, confirmation: nil)
        XCTAssertFalse(item.isBooking, "a plain sightseeing stop isn't a booking")
    }

    func testFoodWithNoMarkerIsNotABooking() {
        let item = TestFixtures.makeItineraryItem(category: .food, startsAt: .now, confirmation: nil)
        XCTAssertFalse(item.isBooking, "a plain meal plan isn't a booking")
    }

    func testActivityWithTicketRefIsABooking() {
        var details = ItemDetails.empty
        details.ticketRef = "TKT-1000"
        let item = TestFixtures.makeItineraryItem(category: .activity, startsAt: .now, confirmation: nil, details: details)
        XCTAssertTrue(item.isBooking, "a ticketed activity is a booking even when the code lives in details, not confirmation")
    }

    func testFoodWithReservationNameIsABooking() {
        var details = ItemDetails.empty
        details.reservationName = "Naveen"
        let item = TestFixtures.makeItineraryItem(category: .food, startsAt: .now, confirmation: nil, details: details)
        XCTAssertTrue(item.isBooking, "a named restaurant reservation is a booking even with no top-level confirmation")
    }

    /// The third leg of the marker OR-clause: a non-reservable category with
    /// only the top-level `confirmation` set (no `details` marker at all).
    func testActivityWithOnlyATopLevelConfirmationCodeIsABooking() {
        let item = TestFixtures.makeItineraryItem(category: .activity, startsAt: .now, confirmation: "TKT-2000")
        XCTAssertTrue(item.isBooking)
    }

    // MARK: - status-agnostic (TripView's query is what excludes `suggested`)

    /// `isBooking` must not re-check status — the trusted tabs never see a
    /// `suggested` item because `TripView`'s own `@Query` predicate excludes
    /// it before either tab's `items` array is built (see that init's doc
    /// comment: "filtered at the query itself ... every consumer ... inherits
    /// the exclusion for free"). If `isBooking` also filtered status, that
    /// exclusion would happen twice. Uses a realistic fixture (suggested
    /// flight, confirmation "SKY204X") so this test pins the real shape a
    /// regression would reintroduce.
    func testIsBookingDoesNotFilterByStatusThatIsTripViewsJob() {
        let suggestedFlight = TestFixtures.makeItineraryItem(
            category: .flight, startsAt: .now, confirmation: "SKY204X", status: .suggested
        )
        XCTAssertTrue(
            suggestedFlight.isBooking,
            "isBooking must stay status-agnostic; excluding suggested items is TripView's query's job, not this predicate's"
        )
    }
}
