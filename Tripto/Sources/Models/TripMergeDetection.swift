import Foundation

/// P6.2 (docs/UX_REDESIGN_ROADMAP.md): pure duplicate-trip detection — no
/// SwiftData, no `SyncEngine`, same "Foundation only" split `TripDuplication`
/// already established (`TripMerge.swift` is this feature's SwiftData-
/// touching half, mirroring how `HomeDuplication` sits on top of
/// `TripDuplication`) so the detection matrix is directly unit-testable.
enum TripMergeDetection {
    /// Identical start AND end dates, same normalized destination — the
    /// roadmap's exact rule ("identical date range + same destination").
    /// Compares `DayDate` labels, not raw `Date`/`Calendar.isDate
    /// (inSameDayAs:)`: `Trip.startDate`/`endDate` are already plain
    /// local-midnight calendar days with no time zone of their own (`Trip`'s
    /// own doc comment), and `HomeTripDayLabels`/`HomeRegisters.swift`
    /// already established "compare `DayDate` labels, not raw `Date`s" as
    /// this codebase's convention for exactly this class of trip-date
    /// comparison.
    static func isDuplicate(_ first: Trip, _ second: Trip, calendar: Calendar = .current) -> Bool {
        guard DayDate.from(first.startDate, calendar: calendar) == DayDate.from(second.startDate, calendar: calendar),
            DayDate.from(first.endDate, calendar: calendar) == DayDate.from(second.endDate, calendar: calendar)
        else { return false }
        let key = normalizedDestination(first)
        return !key.isEmpty && key == normalizedDestination(second)
    }

    /// Trimmed + lowercased — "Okinawa" / "okinawa " / "OKINAWA" all match.
    /// An empty destination never matches another empty one (`isDuplicate`'s
    /// own `!key.isEmpty` guard) — two blank-destination trips with the same
    /// dates aren't necessarily the same place, mirroring `TripCard
    /// .locationText`'s own "never match/render on blank content" caution.
    static func normalizedDestination(_ trip: Trip) -> String {
        trip.destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// For every trip in `orderedTrips` (already sorted — `HomeTripOrdering
    /// .ahead`'s own comparator is the only real caller), the trip
    /// immediately preceding it, keyed by id, whenever the two are
    /// duplicates. Adjacent-pair only, matching the roadmap's own reasoning
    /// ("identical dates means the pair is always adjacent" in a list
    /// sorted soonest-start-first) — a real duplicate pair never needs a
    /// non-adjacent scan, and this also naturally chains through a rare 3-
    /// (or more-) way tie: the third trip in an identical-dates trio pairs
    /// with the second, the second with the first, each strip reading "same
    /// dates as the trip above" about the card directly above it. A trip is
    /// never its own survivor and never appears twice as a shell (each
    /// index only ever compares to the ONE index before it).
    static func survivorByShellId(in orderedTrips: [Trip], calendar: Calendar = .current) -> [UUID: Trip] {
        guard orderedTrips.count > 1 else { return [:] }
        var result: [UUID: Trip] = [:]
        for index in 1..<orderedTrips.count {
            let previous = orderedTrips[index - 1]
            let current = orderedTrips[index]
            if isDuplicate(previous, current, calendar: calendar) {
                result[current.id] = previous
            }
        }
        return result
    }
}
