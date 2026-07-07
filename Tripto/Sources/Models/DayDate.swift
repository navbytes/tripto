import Foundation

/// A calendar day with no time-of-day or time zone component — the wire
/// representation of a Postgres `date` column (`trips.start_date`/`end_date`).
///
/// This is deliberately a *different* type from the `timestamptz` instants
/// on `ItineraryItem` (§7.4's UTC-plus-tz rule). A trip's start/end date is
/// not "an instant that happened to fall on a day" — it's just a day, the
/// same day everywhere, so it needs none of the zone machinery and none of
/// the UTC-vs-local pitfalls that come with it. Encodes/decodes as a plain
/// "yyyy-MM-dd" string (PostgREST's format for `date` columns), independent
/// of whatever `Date` strategy `JSONCoding`'s encoder/decoder use for
/// `timestamptz` columns elsewhere in the same payload — a custom
/// `Codable` type dispatches to its own `init(from:)`/`encode(to:)` rather
/// than the container's date strategy.
struct DayDate: Codable, Hashable, Comparable, Sendable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = DayDate.parse(raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid date-only string: \(raw)"
            )
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }

    var stringValue: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func parse(_ raw: String) -> DayDate? {
        // Tolerate a full timestamp arriving where a date was expected by
        // only looking at the leading "yyyy-MM-dd" — defensive, not
        // expected in practice since `date` columns never emit a time part.
        let datePart = raw.prefix(10)
        let parts = datePart.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2])
        else { return nil }
        return DayDate(year: y, month: m, day: d)
    }

    static func < (lhs: DayDate, rhs: DayDate) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// The local-midnight `Date` for this calendar day, in `calendar`'s own
    /// time zone (defaults to the device's current zone). Intentionally
    /// *not* pinned to UTC: a trip's dates are wall-calendar days, and
    /// comparing "is today past the trip's end date" only makes sense
    /// against *today as the viewer currently perceives it* — see
    /// `TripDateBucketing` for why this matters at the boundary days.
    func asDate(calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components) ?? .distantPast
    }

    /// Extracts the calendar day from a `Date`, using `calendar` (defaults
    /// to the device's current calendar/time zone).
    static func from(_ date: Date, calendar: Calendar = .current) -> DayDate {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return DayDate(
            year: components.year ?? 1970,
            month: components.month ?? 1,
            day: components.day ?? 1
        )
    }

    static func today(calendar: Calendar = .current) -> DayDate {
        from(Date(), calendar: calendar)
    }
}
