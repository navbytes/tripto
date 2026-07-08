import XCTest
@testable import Tripto

/// `details.tags` round-trips the `ItemDetails` codec (this milestone's
/// brief §5) — the kid-aware tags (BUILD_PLAN.md §5.4) live in the same
/// jsonb blob as the flight/hotel/activity/food fields `ItemDetails`
/// already models, so this exercises the `AnyJSON` array plumbing this
/// milestone adds to `ItemDetails.json`/`init(json:)`.
final class ItemDetailsTagsTests: XCTestCase {
    func testTagsRoundTripThroughJSONRepresentation() {
        var details = ItemDetails.empty
        details.tags = [ItemTag.nap.rawValue, ItemTag.strollerOk.rawValue]

        let roundTripped = ItemDetails(json: details.json)
        XCTAssertEqual(roundTripped.tags, ["nap", "stroller-ok"])
    }

    func testEmptyTagsOmitsTheKeyEntirelyRatherThanAnEmptyArray() {
        let details = ItemDetails.empty
        guard case .object(let object) = details.json else {
            return XCTFail("expected details.json to be an object")
        }
        XCTAssertNil(object["tags"], "an empty tags array shouldn't round-trip as a stray `[]` in the jsonb blob")
    }

    func testTagsSurviveAlongsideCategorySpecificFields() {
        var details = ItemDetails.empty
        details.airline = "TAP Air Portugal"
        details.flightNo = "TP1234"
        details.tags = [ItemTag.kidsMenu.rawValue]

        let roundTripped = ItemDetails(json: details.json)
        XCTAssertEqual(roundTripped.airline, "TAP Air Portugal")
        XCTAssertEqual(roundTripped.flightNo, "TP1234")
        XCTAssertEqual(roundTripped.tags, ["kids-menu"])
    }

    /// `tags` is plain `[String]`, not backed by an enum on the model — a
    /// future tag this build doesn't recognize must still round-trip, not
    /// be silently dropped (mirrors how every other unrecognized raw-string
    /// enum in this app degrades — see `Enums.swift`'s doc comment).
    func testUnrecognizedTagStringsSurviveTheRoundTrip() {
        var details = ItemDetails.empty
        details.tags = ["some-future-tag"]
        XCTAssertEqual(ItemDetails(json: details.json).tags, ["some-future-tag"])
    }

    func testItemDetailsDefaultsToNoTags() {
        XCTAssertEqual(ItemDetails.empty.tags, [])
    }

    func testItemTagRawValuesMatchTheBriefsExactStrings() {
        XCTAssertEqual(ItemTag.nap.rawValue, "nap")
        XCTAssertEqual(ItemTag.strollerOk.rawValue, "stroller-ok")
        XCTAssertEqual(ItemTag.kidsMenu.rawValue, "kids-menu")
    }

    // MARK: - Through the full ItineraryItem/DTO round trip (matches
    // DTORoundTripTests' "DTO -> Model -> DTO" shape, scoped to tags)

    func testTagsRoundTripThroughItineraryItemDetailsJSON() {
        let item = TestFixtures.makeItineraryItem(startsAt: .now)
        var details = ItemDetails.empty
        details.tags = [ItemTag.nap.rawValue]
        item.details = details

        XCTAssertEqual(item.details.tags, ["nap"])

        let dto = item.toDTO()
        let rebuilt = ItineraryItem(dto: dto)
        XCTAssertEqual(rebuilt.details.tags, ["nap"])
    }

    /// Setting just `.tags` through the computed `details` property must
    /// not clobber other already-set fields — the get/modify/set pattern
    /// `DemoSeeder.swift`'s family-layer tagging relies on.
    func testMutatingTagsInPlacePreservesOtherDetailsFields() {
        let item = TestFixtures.makeItineraryItem(category: .activity, startsAt: .now)
        var initial = ItemDetails.empty
        initial.address = "Parque das Nações, Lisbon"
        initial.ticketRef = "TKT-1000"
        item.details = initial

        item.details.tags = [ItemTag.strollerOk.rawValue]

        XCTAssertEqual(item.details.address, "Parque das Nações, Lisbon")
        XCTAssertEqual(item.details.ticketRef, "TKT-1000")
        XCTAssertEqual(item.details.tags, ["stroller-ok"])
    }
}
