import Foundation

/// Tiny IATA→IANA-zone map for the flight form (ACCEPTANCE.md "(a)" case
/// A2: the departure time's zone label should follow the typed airport, not
/// the device's locale). Deliberately just the major hubs — v1 has no
/// airport database (BUILD_PLAN.md §4.3 allows "a manual tz picker
/// defaulted intelligently"), so an unknown code simply leaves the manual
/// zone picker as-is; a known one snaps the picker's default, still fully
/// user-overridable.
enum AirportTimeZones {
    private static let map: [String: String] = [
        // North America
        "JFK": "America/New_York", "EWR": "America/New_York", "LGA": "America/New_York",
        "BOS": "America/New_York", "MIA": "America/New_York", "ATL": "America/New_York",
        "ORD": "America/Chicago", "DFW": "America/Chicago", "DEN": "America/Denver",
        "LAX": "America/Los_Angeles", "SFO": "America/Los_Angeles", "SEA": "America/Los_Angeles",
        "YYZ": "America/Toronto", "YVR": "America/Vancouver", "MEX": "America/Mexico_City",
        // Europe
        "LIS": "Europe/Lisbon", "OPO": "Europe/Lisbon",
        "LHR": "Europe/London", "LGW": "Europe/London", "DUB": "Europe/Dublin",
        "CDG": "Europe/Paris", "ORY": "Europe/Paris", "AMS": "Europe/Amsterdam",
        "FRA": "Europe/Berlin", "MUC": "Europe/Berlin", "ZRH": "Europe/Zurich",
        "MAD": "Europe/Madrid", "BCN": "Europe/Madrid", "FCO": "Europe/Rome",
        "ATH": "Europe/Athens", "IST": "Europe/Istanbul", "KEF": "Atlantic/Reykjavik",
        // Middle East / Asia / Pacific
        "DXB": "Asia/Dubai", "DOH": "Asia/Qatar",
        "DEL": "Asia/Kolkata", "BOM": "Asia/Kolkata", "BLR": "Asia/Kolkata",
        "SIN": "Asia/Singapore", "HKG": "Asia/Hong_Kong", "BKK": "Asia/Bangkok",
        "NRT": "Asia/Tokyo", "HND": "Asia/Tokyo", "KIX": "Asia/Tokyo",
        "ICN": "Asia/Seoul", "PEK": "Asia/Shanghai", "PVG": "Asia/Shanghai",
        "SYD": "Australia/Sydney", "MEL": "Australia/Melbourne", "AKL": "Pacific/Auckland",
        // South America / Africa
        "GRU": "America/Sao_Paulo", "EZE": "America/Argentina/Buenos_Aires",
        "GIG": "America/Sao_Paulo", "BOG": "America/Bogota", "SCL": "America/Santiago",
        "JNB": "Africa/Johannesburg", "CPT": "Africa/Johannesburg", "CAI": "Africa/Cairo",
        "NBO": "Africa/Nairobi", "CMN": "Africa/Casablanca",
    ]

    /// The IANA zone identifier for a 3-letter IATA code, or nil for a code
    /// this map doesn't know. Case-insensitive, whitespace-tolerant.
    static func tzIdentifier(for iata: String) -> String? {
        map[iata.trimmingCharacters(in: .whitespaces).uppercased()]
    }

    /// Bug fix: `BookingDetailView`'s flight header used to show
    /// `ItineraryTimeZone.citySegment(of:)` on the *timezone* as the
    /// departure/arrival city — wrong whenever an airport doesn't share its
    /// timezone's canonical city (EWR → "America/New_York" → "New York",
    /// not "Newark"; SFO/OAK/SJC all → "Los Angeles" under the old logic).
    /// This is the actual airport city for the same hub list `map` covers,
    /// keyed identically so both stay in sync. Falls back to the timezone's
    /// city (still better than nothing) for any code neither map knows —
    /// see call site.
    private static let cityNames: [String: String] = [
        "JFK": "New York", "EWR": "Newark", "LGA": "New York",
        "BOS": "Boston", "MIA": "Miami", "ATL": "Atlanta",
        "ORD": "Chicago", "DFW": "Dallas", "DEN": "Denver",
        "LAX": "Los Angeles", "SFO": "San Francisco", "SEA": "Seattle",
        "YYZ": "Toronto", "YVR": "Vancouver", "MEX": "Mexico City",
        "LIS": "Lisbon", "OPO": "Porto",
        "LHR": "London", "LGW": "London", "DUB": "Dublin",
        "CDG": "Paris", "ORY": "Paris", "AMS": "Amsterdam",
        "FRA": "Frankfurt", "MUC": "Munich", "ZRH": "Zurich",
        "MAD": "Madrid", "BCN": "Barcelona", "FCO": "Rome",
        "ATH": "Athens", "IST": "Istanbul", "KEF": "Reykjavik",
        "DXB": "Dubai", "DOH": "Doha",
        "DEL": "Delhi", "BOM": "Mumbai", "BLR": "Bangalore",
        "SIN": "Singapore", "HKG": "Hong Kong", "BKK": "Bangkok",
        "NRT": "Tokyo", "HND": "Tokyo", "KIX": "Osaka",
        "ICN": "Seoul", "PEK": "Beijing", "PVG": "Shanghai",
        "SYD": "Sydney", "MEL": "Melbourne", "AKL": "Auckland",
        "GRU": "S\u{E3}o Paulo", "EZE": "Buenos Aires",
        "GIG": "Rio de Janeiro", "BOG": "Bogot\u{E1}", "SCL": "Santiago",
        "JNB": "Johannesburg", "CPT": "Cape Town", "CAI": "Cairo",
        "NBO": "Nairobi", "CMN": "Casablanca",
    ]

    /// The actual airport city for a 3-letter IATA code, or nil for a code
    /// this map doesn't know (caller should fall back to something else,
    /// same "unknown code degrades gracefully" contract as `tzIdentifier`).
    static func cityName(for iata: String) -> String? {
        cityNames[iata.trimmingCharacters(in: .whitespaces).uppercased()]
    }
}
