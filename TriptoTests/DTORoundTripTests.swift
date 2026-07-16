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
          "source": "manual",
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

    /// F3 (backend account-deletion migration, `ON DELETE SET NULL`): an
    /// item a since-deleted user added to someone else's trip comes back
    /// over the wire with `created_by = null` instead of failing to decode
    /// — and a nil creator must never be usable as a companion's "own
    /// item" edit path (`ItemPermissions.canEdit`'s key use of this field).
    func testItineraryItemDTODecodesNullCreatedByAndDeniesCompanionOwnPathEdit() throws {
        let id = UUID()
        let tripId = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "trip_id": "\(tripId.uuidString)",
          "category": "activity",
          "title": "City walk",
          "starts_at": "2026-05-14T12:20:00.000+00:00",
          "ends_at": null,
          "tz": "America/New_York",
          "location_name": "",
          "location_lat": null,
          "location_lng": null,
          "confirmation": null,
          "notes": null,
          "details": {},
          "status": "confirmed",
          "source": "manual",
          "created_by": null,
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56.789+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(ItineraryItemDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.createdBy)

        let model = ItineraryItem(dto: dto)
        XCTAssertNil(model.createdBy)

        // Must never fall through to "mine" just because a companion's own
        // id happens to be compared against a nil creator.
        let someCompanion = UUID()
        XCTAssertFalse(
            ItemPermissions.canEdit(item: model, role: .companion, userId: someCompanion),
            "an anonymized item (creator account deleted) must never be editable via the companion own-item path"
        )
        // The organizer's "edit anything" path is unaffected by the nil creator.
        XCTAssertTrue(ItemPermissions.canEdit(item: model, role: .organizer, userId: someCompanion))
    }

    /// P2 (on-device paste-import): the two tests above only ever exercise
    /// `source: "manual"` — the same value `sourceRaw`/`source` default to
    /// — so a wiring bug that silently dropped the field on either side of
    /// `init(dto:)`/`apply(_:)`/`toDTO()` (e.g. forgetting to pass
    /// `sourceRaw: dto.source`) would go undetected by them. This pins the
    /// non-default value the on-device path actually writes, round-tripped
    /// through DTO -> model -> DTO, the same wire mechanism `PasteImportSheet
    /// .insertValidatedItineraryItems` pushes through the sync outbox.
    func testItineraryItemDTORoundTripsNonDefaultSource() throws {
        let id = UUID()
        let tripId = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "trip_id": "\(tripId.uuidString)",
          "category": "flight",
          "title": "TAP TP1234",
          "starts_at": "2026-05-14T12:20:00.000+00:00",
          "ends_at": null,
          "tz": "America/New_York",
          "location_name": "",
          "location_lat": null,
          "location_lng": null,
          "confirmation": null,
          "notes": null,
          "details": {},
          "status": "suggested",
          "source": "text_import",
          "created_by": null,
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56.789+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(ItineraryItemDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.source, "text_import")

        let model = ItineraryItem(dto: dto)
        XCTAssertEqual(model.source, .textImport)
        XCTAssertEqual(model.sourceRaw, "text_import")

        XCTAssertEqual(model.toDTO(), dto)

        let reencoded = try JSONCoding.encoder.encode(dto)
        let redecoded = try JSONCoding.decoder.decode(ItineraryItemDTO.self, from: reencoded)
        XCTAssertEqual(redecoded.source, "text_import")
    }

    /// EI-4 (`itinerary_items.sender_verified`): a payload from a server
    /// that hasn't shipped this column yet must still decode — the exact
    /// scenario this additive/nullable field exists to survive. `Bool?`'s
    /// synthesized `decodeIfPresent` handles a wholly absent key the same
    /// way it handles an explicit `null`, so no custom decoding is needed.
    /// Also pins that `nil` never trips the review-UI badge/callout
    /// predicate (`isFromUnverifiedSender`).
    func testItineraryItemDTODecodesAbsentSenderVerifiedAsNilAndDoesNotBadge() throws {
        let id = UUID()
        let tripId = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "trip_id": "\(tripId.uuidString)",
          "category": "activity",
          "title": "City walk",
          "starts_at": "2026-05-14T12:20:00.000+00:00",
          "ends_at": null,
          "tz": "America/New_York",
          "location_name": "",
          "location_lat": null,
          "location_lng": null,
          "confirmation": null,
          "notes": null,
          "details": {},
          "status": "confirmed",
          "source": "manual",
          "created_by": null,
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56.789+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(ItineraryItemDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.senderVerified)

        let model = ItineraryItem(dto: dto)
        XCTAssertNil(model.senderVerified)
        XCTAssertFalse(model.isFromUnverifiedSender)
        XCTAssertEqual(model.toDTO(), dto)
    }

    /// EI-4: `sender_verified: false` — the forwarder isn't a trip member —
    /// round-trips through both `init(dto:)` and `apply(_:)` (the pull-path
    /// mutation `SyncStore.applyItineraryItems` actually calls), and is the
    /// one case that must flip the review-UI predicate to `true`.
    func testItineraryItemDTORoundTripsSenderVerifiedFalseAndBadges() throws {
        let id = UUID()
        let tripId = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "trip_id": "\(tripId.uuidString)",
          "category": "flight",
          "title": "TAP TP1234",
          "starts_at": "2026-05-14T12:20:00.000+00:00",
          "ends_at": null,
          "tz": "America/New_York",
          "location_name": "",
          "location_lat": null,
          "location_lng": null,
          "confirmation": null,
          "notes": null,
          "details": {},
          "status": "suggested",
          "source": "email_import",
          "sender_verified": false,
          "created_by": null,
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56.789+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(ItineraryItemDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.senderVerified, false)

        let model = ItineraryItem(dto: dto)
        XCTAssertEqual(model.senderVerified, false)
        XCTAssertTrue(model.isFromUnverifiedSender)
        XCTAssertEqual(model.toDTO(), dto)

        // The pull-path mutation of an already-existing local row, not just
        // first insert via `init(dto:)` — `SyncStore.applyItineraryItems`
        // calls this on every row it already has a local copy of.
        let existing = TestFixtures.makeItineraryItem(startsAt: .now)
        existing.senderVerified = true
        existing.apply(dto)
        XCTAssertEqual(existing.senderVerified, false)
        XCTAssertTrue(existing.isFromUnverifiedSender)
    }

    /// EI-4: `sender_verified: true` — the forwarder IS a trip member —
    /// must decode and round-trip like any other value, but must NOT badge;
    /// only an explicit `false` does (see `isFromUnverifiedSender`'s doc
    /// comment on `ItineraryItem`).
    func testItineraryItemDTORoundTripsSenderVerifiedTrueAndDoesNotBadge() throws {
        let id = UUID()
        let tripId = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "trip_id": "\(tripId.uuidString)",
          "category": "flight",
          "title": "TAP TP1234",
          "starts_at": "2026-05-14T12:20:00.000+00:00",
          "ends_at": null,
          "tz": "America/New_York",
          "location_name": "",
          "location_lat": null,
          "location_lng": null,
          "confirmation": null,
          "notes": null,
          "details": {},
          "status": "suggested",
          "source": "email_import",
          "sender_verified": true,
          "created_by": null,
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56.789+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(ItineraryItemDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.senderVerified, true)

        let model = ItineraryItem(dto: dto)
        XCTAssertEqual(model.senderVerified, true)
        XCTAssertFalse(model.isFromUnverifiedSender)
        XCTAssertEqual(model.toDTO(), dto)
    }

    // MARK: - P8a (avatar photos): `profiles.avatar_path`/`trip_profiles.avatar_path`

    /// A server that hasn't shipped this column yet (or a row with no photo)
    /// omits the key entirely — same additive/nullable contract as
    /// `ItineraryItemDTO.senderVerified`'s own doc comment.
    func testProfileDTODecodesAbsentAvatarPathAsNilAndRoundTrips() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "display_name": "Priya",
          "avatar_color": "amber",
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56+00:00"
        }
        """

        let dto = try JSONCoding.decoder.decode(ProfileDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.avatarPath)

        let model = Profile(dto: dto)
        XCTAssertNil(model.avatarPath)
        XCTAssertEqual(model.toDTO(), dto)
    }

    /// A real uploaded path round-trips through DTO -> Model -> DTO, and
    /// through `apply(_:)` (the pull-path mutation of an already-existing
    /// local row), not just first insert via `init(dto:)`.
    func testProfileDTORoundTripsAPresentAvatarPath() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "display_name": "Priya",
          "avatar_color": "amber",
          "avatar_path": "\(id.uuidString)/photo.jpg",
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56+00:00"
        }
        """

        let dto = try JSONCoding.decoder.decode(ProfileDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.avatarPath, "\(id.uuidString)/photo.jpg")

        let model = Profile(dto: dto)
        XCTAssertEqual(model.avatarPath, "\(id.uuidString)/photo.jpg")
        XCTAssertEqual(model.toDTO(), dto)

        let existing = Profile(
            id: id, displayName: "Priya", avatarColor: "amber", avatarPath: nil,
            createdAt: .now, updatedAt: .now
        )
        existing.apply(dto)
        XCTAssertEqual(existing.avatarPath, "\(id.uuidString)/photo.jpg")

        let reencoded = try JSONCoding.encoder.encode(dto)
        let redecoded = try JSONCoding.decoder.decode(ProfileDTO.self, from: reencoded)
        XCTAssertEqual(redecoded.avatarPath, dto.avatarPath)
    }

    /// Same absent-column contract as `Profile`'s own test above.
    func testTripProfileDTODecodesAbsentAvatarPathAsNilAndRoundTrips() throws {
        let id = UUID()
        let tripId = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "trip_id": "\(tripId.uuidString)",
          "display_name": "Grandma",
          "avatar_color": "sky",
          "linked_user_id": null,
          "created_at": "2026-07-08T12:34:56.789+00:00"
        }
        """

        let dto = try JSONCoding.decoder.decode(TripProfileDTO.self, from: Data(json.utf8))
        XCTAssertNil(dto.avatarPath)

        let model = TripProfile(dto: dto)
        XCTAssertNil(model.avatarPath)
        XCTAssertEqual(model.toDTO(), dto)
    }

    /// Same present-value round-trip as `Profile`'s own test above, including
    /// `apply(_:)` mutating an already-existing local row (the pull-path
    /// `SyncStore.applyTripProfiles` actually exercises).
    func testTripProfileDTORoundTripsAPresentAvatarPath() throws {
        let id = UUID()
        let tripId = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "trip_id": "\(tripId.uuidString)",
          "display_name": "Grandma",
          "avatar_color": "sky",
          "avatar_path": "\(tripId.uuidString)/grandma.jpg",
          "linked_user_id": null,
          "created_at": "2026-07-08T12:34:56.789+00:00"
        }
        """

        let dto = try JSONCoding.decoder.decode(TripProfileDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.avatarPath, "\(tripId.uuidString)/grandma.jpg")

        let model = TripProfile(dto: dto)
        XCTAssertEqual(model.avatarPath, "\(tripId.uuidString)/grandma.jpg")
        XCTAssertEqual(model.toDTO(), dto)

        let existing = TripProfile(
            id: id, tripId: tripId, displayName: "Grandma", avatarColor: "sky",
            avatarPath: nil, linkedUserId: nil, createdAt: .now
        )
        existing.apply(dto)
        XCTAssertEqual(existing.avatarPath, "\(tripId.uuidString)/grandma.jpg")
    }

    // MARK: - P8b (photo trip covers): `trips.cover_image_path`/
    // `cover_credit_name`/`cover_credit_url`

    /// Same additive/nullable contract as `Profile.avatarPath`'s own test
    /// above — a server that hasn't shipped these columns yet (or a trip
    /// with no cover photo) omits the keys entirely.
    /// `testTripDTODecodesBothTimestampFormsAndRoundTripsThroughTheModel`
    /// above already exercises this implicitly (its own fixture predates
    /// P8b and carries none of these keys); this pins it explicitly.
    func testTripDTODecodesAbsentCoverImagePathAndCreditFieldsAsNilAndRoundTrips() throws {
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
        XCTAssertNil(dto.coverImagePath)
        XCTAssertNil(dto.coverCreditName)
        XCTAssertNil(dto.coverCreditUrl)

        let model = Trip(dto: dto)
        XCTAssertNil(model.coverImagePath)
        XCTAssertNil(model.coverCreditName)
        XCTAssertNil(model.coverCreditUrl)
        XCTAssertEqual(model.toDTO(), dto)
    }

    /// A user's own `PhotosPicker` photo — `coverImagePath` present, no
    /// credit (P8b never writes one). Round-trips through DTO -> Model ->
    /// DTO, and through `apply(_:)` (the pull-path mutation of an
    /// already-existing local row), not just first insert via `init(dto:)`.
    func testTripDTORoundTripsAPresentCoverImagePathWithNoCredit() throws {
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
          "cover_image_path": "\(id.uuidString)/cover.jpg",
          "trip_type": "family",
          "created_by": "\(createdBy.uuidString)",
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(TripDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.coverImagePath, "\(id.uuidString)/cover.jpg")
        XCTAssertNil(dto.coverCreditName)
        XCTAssertNil(dto.coverCreditUrl)

        let model = Trip(dto: dto)
        XCTAssertEqual(model.coverImagePath, "\(id.uuidString)/cover.jpg")
        XCTAssertEqual(model.toDTO(), dto)

        let existing = TestFixtures.makeTrip(id: id, startDate: .now, endDate: .now, createdBy: createdBy)
        existing.apply(dto)
        XCTAssertEqual(existing.coverImagePath, "\(id.uuidString)/cover.jpg")

        let reencoded = try JSONCoding.encoder.encode(dto)
        let redecoded = try JSONCoding.decoder.decode(TripDTO.self, from: reencoded)
        XCTAssertEqual(redecoded, dto)
    }

    /// P8c (not yet writing these — this app only ever emits `nil` for both
    /// today, but a future P8c row, or one already pulled from another
    /// client, must still decode correctly): a Pexels-sourced cover carries
    /// both credit fields alongside its path. This is the test that would
    /// catch a `coverCreditURL`-spelling regression (see `TripDTO
    /// .coverCreditUrl`'s own doc comment) — a wrongly-spelled property
    /// would silently decode this real payload's `cover_credit_url` as `nil`
    /// instead of failing loudly, so asserting the actual non-nil value
    /// here is load-bearing, not decorative.
    func testTripDTORoundTripsPresentCreditFieldsAlongsideACoverImagePath() throws {
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
          "cover_image_path": "\(id.uuidString)/pexels-cover.jpg",
          "cover_credit_name": "Priya Sharma",
          "cover_credit_url": "https://www.pexels.com/photo/12345",
          "trip_type": "family",
          "created_by": "\(createdBy.uuidString)",
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(TripDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.coverImagePath, "\(id.uuidString)/pexels-cover.jpg")
        XCTAssertEqual(dto.coverCreditName, "Priya Sharma")
        XCTAssertEqual(dto.coverCreditUrl, "https://www.pexels.com/photo/12345")

        let model = Trip(dto: dto)
        XCTAssertEqual(model.coverCreditName, "Priya Sharma")
        XCTAssertEqual(model.coverCreditUrl, "https://www.pexels.com/photo/12345")
        XCTAssertEqual(model.toDTO(), dto)

        let reencoded = try JSONCoding.encoder.encode(dto)
        let redecoded = try JSONCoding.decoder.decode(TripDTO.self, from: reencoded)
        XCTAssertEqual(redecoded, dto)
    }

    /// Job A hardening (P8b harden pass): a server (or a bulk-edit/admin
    /// tool) could plausibly send `""` instead of `null` for any of these
    /// three columns — `TripDTO`'s additive/nullable contract (see `Trip
    /// .coverImagePath`'s own doc comment) says nothing about which one a
    /// given row actually carries, and `String?` decoding treats an
    /// explicit `""` as `Optional("")`, never folding it into `nil` the way
    /// an absent key does. Confirms the whole DTO -> Model -> DTO chain (and
    /// `apply(_:)`, the pull-path mutation of an already-existing local row)
    /// preserves that exact distinction — an empty string stays an empty
    /// string, never silently normalized to nil or vice versa — rather than
    /// crashing or losing data in either direction.
    func testTripDTORoundTripsEmptyStringCoverFieldsDistinctFromNil() throws {
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
          "cover_image_path": "",
          "cover_credit_name": "",
          "cover_credit_url": "",
          "trip_type": "family",
          "created_by": "\(createdBy.uuidString)",
          "created_at": "2026-07-08T12:34:56.789+00:00",
          "updated_at": "2026-07-08T12:34:56+00:00",
          "updated_by": null
        }
        """

        let dto = try JSONCoding.decoder.decode(TripDTO.self, from: Data(json.utf8))
        // The load-bearing assertion: an explicit "" decodes as a non-nil
        // empty string, never folded into nil the way an absent key is.
        XCTAssertNotNil(dto.coverImagePath)
        XCTAssertEqual(dto.coverImagePath, "")
        XCTAssertEqual(dto.coverCreditName, "")
        XCTAssertEqual(dto.coverCreditUrl, "")

        let model = Trip(dto: dto)
        XCTAssertEqual(model.coverImagePath, "")
        XCTAssertEqual(model.toDTO(), dto)

        // `apply(_:)` must overwrite a REAL prior photo down to this empty
        // string too, not leave the old value in place because "" reads as
        // falsy — the pull path must never treat this as "nothing to apply."
        let existing = TestFixtures.makeTrip(id: id, startDate: .now, endDate: .now, createdBy: createdBy)
        existing.coverImagePath = "\(id.uuidString)/real-cover.jpg"
        existing.apply(dto)
        XCTAssertEqual(existing.coverImagePath, "")

        let reencoded = try JSONCoding.encoder.encode(dto)
        let redecoded = try JSONCoding.decoder.decode(TripDTO.self, from: reencoded)
        XCTAssertEqual(redecoded, dto)
    }
}
