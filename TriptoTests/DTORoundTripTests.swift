import XCTest
@testable import Tripto

/// DTO <-> Model round trips through the one shared `JSONCoding` mechanism,
/// against realistic PostgREST payloads that mix fractional and
/// non-fractional `timestamptz` strings in the same object (PostgREST only
/// emits fractional seconds when they're non-zero).
final class DTORoundTripTests: XCTestCase {
    func testTripDTODecodesBothTimestampFormsAndRoundTripsThroughTheModel() throws {
        let id = UUID()
        let createdBy = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "title": "Lisbon",
          "destination": "Lisbon, Portugal",
          "country_code": "PT",
          "start_date": "2026-05-14",
          "end_date": "2026-05-20",
          "cover_gradient": "dusk",
          "trip_type": "family",
          "created_by": "\(createdBy.uuidString)",
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(TripDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.id, id)
        XCTAssertEqual(dto.title, "Lisbon")
        XCTAssertEqual(dto.startDate, DayDate(year: 2026, month: 5, day: 14))
        XCTAssertEqual(dto.endDate, DayDate(year: 2026, month: 5, day: 20))
        XCTAssertEqual(dto.tripType, "family")
        XCTAssertNil(dto.updatedBy)

        // DTO -> Model -> DTO
        let model = Trip(dto: dto)
        XCTAssertEqual(model.id, id)
        XCTAssertEqual(model.tripType, .family)
        let roundTripped = model.toDTO()
        XCTAssertEqual(roundTripped, dto)

        // DTO -> wire JSON -> DTO (both directions of the shared mechanism)
        let reencoded = try JSONCoding.encoder.encode(dto)
        let redecoded = try JSONCoding.decoder.decode(TripDTO.self, from: reencoded)
        XCTAssertEqual(redecoded, dto)
    }

    func testItineraryItemDTORoundTripsMixedDateFormatsAndDetailsBlob() throws {
        let id = UUID()
        let tripId = UUID()
        let createdBy = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "trip_id": "\(tripId.uuidString)",
          "category": "flight",
          "title": "TAP TP1234",
          "starts_at": "2026-05-14T12:20:00.000+00:00",
          "ends_at": "2026-05-14T19:15:00+00:00",
          "tz": "America/New_York",
          "location_name": "JFK",
          "location_lat": 40.6413,
          "location_lng": -73.7781,
          "confirmation": "QK7P2M",
          "notes": null,
          "details": {"airline": "TAP", "flight_no": "TP1234"},
          "status": "confirmed",
          "created_by": "\(createdBy.uuidString)",
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56.789+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(ItineraryItemDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.category, "flight")
        XCTAssertEqual(dto.tz, "America/New_York")
        XCTAssertEqual(dto.locationLat, 40.6413)
        XCTAssertNil(dto.notes)
        guard case .object(let detailsObject) = dto.details else {
            return XCTFail("expected details to decode as a JSON object")
        }
        XCTAssertEqual(detailsObject["airline"], .string("TAP"))
        XCTAssertEqual(detailsObject["flight_no"], .string("TP1234"))

        // A 6h55m JFK->LIS block time (ACCEPTANCE.md "(a)") — sanity check
        // that both timestamp forms decoded to the instants they should.
        let blockTime = dto.endsAt!.timeIntervalSince(dto.startsAt)
        XCTAssertEqual(blockTime, 6 * 3600 + 55 * 60, accuracy: 1)

        // DTO -> Model -> DTO, including the `details` JSONB blob's keys
        // surviving byte-for-byte through the local `detailsJSON` text form.
        let model = ItineraryItem(dto: dto)
        XCTAssertEqual(model.detailsJSON.contains("flight_no"), true)
        let roundTripped = model.toDTO()
        XCTAssertEqual(roundTripped.details, dto.details)
        XCTAssertEqual(roundTripped, dto)
    }
}
