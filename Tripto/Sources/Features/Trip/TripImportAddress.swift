import Foundation

/// EI-2 (`docs/EMAIL_IMPORT_PLAN.md`): thin wrapper around
/// `get_or_create_trip_import_address` — any trip member may call it. Shared
/// by `ItineraryTabView`'s `importTeaser` (empty-itinerary only) and
/// `ShareTripView`'s persistent `importCard`, which is why this moved out of
/// `ItineraryTabView` rather than staying private to it.
enum TripImportAddress {
    static func fetch(tripId: UUID) async throws -> String {
        try await Supa.rpc("get_or_create_trip_import_address", params: TripImportAddressParams(pTripId: tripId))
    }
}

/// `get_or_create_trip_import_address(p_trip_id uuid)` — see
/// `TripImportAddress.fetch(tripId:)`'s doc comment.
private struct TripImportAddressParams: Encodable {
    let pTripId: UUID
}
