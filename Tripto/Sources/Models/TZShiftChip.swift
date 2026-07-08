import Foundation

/// The rail's tz-shift chip text between two consecutive timeline items
/// (this milestone's brief; ACCEPTANCE.md "(a)" point 3). Pure string
/// formatting over already-resolved zones/instants — no view code, no
/// `Calendar.current`.
///
/// Two distinct chips exist, and their triggers differ deliberately:
/// - A **landing chip** follows a flight whose `arrival_tz` differs from its
///   departure `tz` — even when the *next* item is already in the arrival
///   zone (ACCEPTANCE A1.3: the chip "must appear even if the next item is
///   later the same calendar day in the new zone"). The zone change being
///   announced is the flight's own dep→arr crossing, not a prev-vs-next
///   comparison — keying this off `zoneChanged(previous:next:)` would
///   wrongly suppress it for the canonical flight-then-hotel evening.
/// - A **zone-change chip** precedes any item whose primary zone differs
///   from the previous item's *effective* zone (a non-flight crossing, or a
///   residual mismatch a landing chip didn't already cover).
enum TZShiftChip {
    /// "Lands 20:15 in Lisbon — clocks jump ahead 5h" — non-nil only for a
    /// flight with a known arrival instant whose `arrival_tz` differs from
    /// its departure `tz`. N comes from the offset difference *at the
    /// arrival instant* (either side may be in DST), formatted per
    /// `formatHours` (half-hour zones like India render "5.5").
    static func landingText(for flight: ItineraryItem) -> String? {
        guard
            flight.category == .flight,
            let arrivalTzId = flight.details.arrivalTz,
            let arrivalTz = TimeZone(identifier: arrivalTzId),
            arrivalTz.identifier != flight.primaryTz.identifier,
            let endsAt = flight.endsAt
        else { return nil }

        let time = ItineraryTimeZone.timeString(endsAt, in: arrivalTz)
        let city = ItineraryTimeZone.citySegment(of: arrivalTz.identifier)
        let diff = offsetDifferenceInHours(from: flight.primaryTz, to: arrivalTz, at: endsAt)
        let direction = diff >= 0 ? "jump ahead" : "go back"
        return "Lands \(time) in \(city) — clocks \(direction) \(formatHours(abs(diff)))h"
    }

    /// "Times now in Madrid (CEST)" — non-nil when `next`'s primary zone
    /// differs from `previous`'s effective zone (a non-flight change, or
    /// any residual mismatch after a flight whose landing chip announced a
    /// different zone than the next item's).
    static func zoneChangeText(previous: ItineraryItem, next: ItineraryItem) -> String? {
        guard ItineraryTimeZone.zoneChanged(from: previous, to: next) else { return nil }
        let toTz = next.primaryTz
        let city = ItineraryTimeZone.citySegment(of: toTz.identifier)
        let abbr = ItineraryTimeZone.zoneLabel(for: toTz, at: next.startsAt)
        return "Times now in \(city) (\(abbr))"
    }

    /// Positive when `to` is ahead of `from` at `date` (e.g. flying east),
    /// negative when behind (flying west). Evaluated at a specific instant
    /// (not the zones' "nominal" offsets) since either side may be in DST.
    static func offsetDifferenceInHours(from: TimeZone, to: TimeZone, at date: Date) -> Double {
        Double(to.secondsFromGMT(for: date) - from.secondsFromGMT(for: date)) / 3600
    }

    /// "5" for a whole-hour difference, "5.5" for a half-hour zone like
    /// India (this milestone's brief calls this out explicitly) — trims
    /// trailing zeros so an oddball offset still renders sanely instead of
    /// "5.500000000001" from floating point.
    static func formatHours(_ hours: Double) -> String {
        let rounded = (hours * 100).rounded() / 100
        if rounded == rounded.rounded() {
            return String(Int(rounded))
        }
        var text = String(format: "%.2f", rounded)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}
