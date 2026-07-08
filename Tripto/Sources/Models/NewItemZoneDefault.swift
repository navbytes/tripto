import Foundation

/// Picks the time zone a brand-new itinerary item should default to. A trip is
/// almost always in one place, so the zone its existing items already use is a
/// far better default than the traveler's home/device clock — this is what
/// stops a Lisbon trip from offering "Hong Kong time" (the device zone) on the
/// next flight you add. Falls back to the device zone only for an empty trip.
///
/// Pure and parameterized like the rest of the `Models` date/zone helpers.
enum NewItemZoneDefault {
    static func zone(
        forExistingItemTzIdentifiers identifiers: [String],
        device: TimeZone = .current
    ) -> TimeZone {
        // Most-frequent valid identifier wins; ties break to first-seen.
        // Malformed identifiers are ignored entirely (neither counted nor
        // allowed to force the device fallback).
        var counts: [String: Int] = [:]
        var order: [String] = []
        for id in identifiers where TimeZone(identifier: id) != nil {
            if counts[id] == nil { order.append(id) }
            counts[id, default: 0] += 1
        }
        var bestId: String?
        var bestCount = 0
        for id in order where (counts[id] ?? 0) > bestCount {
            bestCount = counts[id] ?? 0
            bestId = id
        }
        if let bestId, let zone = TimeZone(identifier: bestId) { return zone }
        return device
    }
}
