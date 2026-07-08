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
}
