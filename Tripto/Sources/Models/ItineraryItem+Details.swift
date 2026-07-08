import Foundation
import Supabase

/// Typed view over `ItineraryItem.detailsJSON` (`itinerary_items.details`
/// JSONB, BUILD_PLAN.md §3.3). The column is free-form and category-specific
/// server-side (plain `Json` in `shared/types/tripto.ts` — nothing enforces
/// its shape in Postgres), so this struct is the *one* place in the app that
/// knows the field names for each category. Nothing else hand-rolls a
/// dictionary key against `details`.
///
/// All fields are optional regardless of category — a `Stay` never has
/// `seat`, an in-progress form may not have filled `partySize` yet — callers
/// read only the fields relevant to `item.category`.
struct ItemDetails: Equatable, Sendable {
    // Flight
    var airline: String?
    var flightNo: String?
    var fromIATA: String?
    var toIATA: String?
    var seat: String?
    var terminal: String?
    var gate: String?
    /// IANA identifier of the *arrival* zone — `tz` on the row itself stays
    /// the departure zone (BUILD_PLAN.md §7.4 / this milestone's brief:
    /// "tz = DEPARTURE zone; the ARRIVAL zone goes in details.arrival_tz").
    var arrivalTz: String?

    // Hotel
    var room: String?

    // Activity
    var ticketRef: String?

    // Food
    var partySize: Int?
    var reservationName: String?

    // Transport (rental car / train / ferry / transfer). Pickup is the row's
    // own location_name + starts_at/tz; drop-off is `dropoffLocation` +
    // ends_at, and reuses `arrivalTz` above for the drop-off zone (so a
    // zone-crossing train gets the same tz-shift chip a flight does).
    var provider: String?
    var dropoffLocation: String?

    // Activity & food share a free-text address (flight/hotel use the row's
    // own location_name/lat/lng instead).
    var address: String?

    /// Kid-aware item tags (BUILD_PLAN.md §5.4, this milestone's brief:
    /// "details.tags: [string]") — free-form strings so a future tag never
    /// needs a schema change, but `ItemTag` gives the three v1 values
    /// (nap/stroller-ok/kids-menu) a typed picker/renderer. Applies across
    /// every category, unlike the fields above; defaults to empty, never nil,
    /// so call sites don't need an optional-array dance.
    var tags: [String] = []

    static let empty = ItemDetails()

    init(
        airline: String? = nil, flightNo: String? = nil, fromIATA: String? = nil, toIATA: String? = nil,
        seat: String? = nil, terminal: String? = nil, gate: String? = nil, arrivalTz: String? = nil,
        room: String? = nil, ticketRef: String? = nil, partySize: Int? = nil, reservationName: String? = nil,
        provider: String? = nil, dropoffLocation: String? = nil,
        address: String? = nil, tags: [String] = []
    ) {
        self.airline = airline
        self.flightNo = flightNo
        self.fromIATA = fromIATA
        self.toIATA = toIATA
        self.seat = seat
        self.terminal = terminal
        self.gate = gate
        self.arrivalTz = arrivalTz
        self.room = room
        self.ticketRef = ticketRef
        self.partySize = partySize
        self.reservationName = reservationName
        self.provider = provider
        self.dropoffLocation = dropoffLocation
        self.address = address
        self.tags = tags
    }

    init(json: AnyJSON) {
        guard case .object(let object) = json else { return }
        airline = object["airline"]?.stringValue
        flightNo = object["flight_no"]?.stringValue
        fromIATA = object["from_iata"]?.stringValue
        toIATA = object["to_iata"]?.stringValue
        seat = object["seat"]?.stringValue
        terminal = object["terminal"]?.stringValue
        gate = object["gate"]?.stringValue
        arrivalTz = object["arrival_tz"]?.stringValue
        room = object["room"]?.stringValue
        ticketRef = object["ticket_ref"]?.stringValue
        partySize = object["party_size"]?.intValue
        reservationName = object["reservation_name"]?.stringValue
        provider = object["provider"]?.stringValue
        dropoffLocation = object["dropoff_location"]?.stringValue
        address = object["address"]?.stringValue
        tags = (object["tags"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    var json: AnyJSON {
        var object: JSONObject = [:]
        if let airline { object["airline"] = .string(airline) }
        if let flightNo { object["flight_no"] = .string(flightNo) }
        if let fromIATA { object["from_iata"] = .string(fromIATA) }
        if let toIATA { object["to_iata"] = .string(toIATA) }
        if let seat { object["seat"] = .string(seat) }
        if let terminal { object["terminal"] = .string(terminal) }
        if let gate { object["gate"] = .string(gate) }
        if let arrivalTz { object["arrival_tz"] = .string(arrivalTz) }
        if let room { object["room"] = .string(room) }
        if let ticketRef { object["ticket_ref"] = .string(ticketRef) }
        if let partySize { object["party_size"] = .integer(partySize) }
        if let reservationName { object["reservation_name"] = .string(reservationName) }
        if let provider { object["provider"] = .string(provider) }
        if let dropoffLocation { object["dropoff_location"] = .string(dropoffLocation) }
        if let address { object["address"] = .string(address) }
        if !tags.isEmpty { object["tags"] = .array(tags.map { .string($0) }) }
        return .object(object)
    }
}

/// The three v1 kid-aware tags (this milestone's brief). Raw values are the
/// literal strings stored in `details.tags` — plain `[String]` on the model
/// so a future tag some other client adds is preserved, not dropped, even
/// though this enum only knows these three.
enum ItemTag: String, CaseIterable, Sendable {
    case nap
    case strollerOk = "stroller-ok"
    case kidsMenu = "kids-menu"

    var label: String {
        switch self {
        case .nap: "Nap window"
        case .strollerOk: "Stroller-friendly"
        case .kidsMenu: "Kids\u{2019} menu"
        }
    }

    /// docs/TripAppFamily.jsx's `JustMine` mockup: a Baby glyph rides along
    /// nap/stroller-ok chips only — kids-menu is text-only, no icon. SF
    /// Symbols has no literal "baby" glyph; `figure.and.child.holdinghands`
    /// is the closest built-in stand-in and (deliberately, per the mockup)
    /// shared by both rather than split into two different icons.
    var symbolName: String? {
        switch self {
        case .nap, .strollerOk: "figure.and.child.holdinghands"
        case .kidsMenu: nil
        }
    }

    /// Which item categories this tag is meaningful for — a flight has no
    /// "kids' menu," a hotel stay has no "nap window." Keeps the add form from
    /// offering nonsense tags (persona dry-run: "Kids' menu on a flight").
    var categories: Set<ItemCategory> {
        switch self {
        case .kidsMenu: return [.food]
        case .nap: return [.flight, .activity, .food, .transport]
        case .strollerOk: return [.activity, .food, .transport]
        }
    }

    /// The tags worth offering for a given category, preserving `allCases` order.
    static func allowed(for category: ItemCategory) -> [ItemTag] {
        allCases.filter { $0.categories.contains(category) }
    }
}

extension ItineraryItem {
    /// Reads/writes `detailsJSON` through the typed `ItemDetails` view.
    /// Round-trips via the same passthrough `AnyJSON` mechanism as the
    /// DTO boundary (`ItineraryItemDTO.details` / `AnyJSON.jsonText`) so an
    /// unrecognized key some future milestone adds is merely ignored here,
    /// never dropped from what actually gets persisted... except that a
    /// `set` *does* rewrite the whole blob from the typed struct's known
    /// fields, which is fine while `ItemDetails` covers every key this app
    /// ever writes (v1: nothing else touches `details`).
    var details: ItemDetails {
        get { ItemDetails(json: AnyJSON(jsonText: detailsJSON)) }
        set { detailsJSON = newValue.json.jsonText }
    }
}
