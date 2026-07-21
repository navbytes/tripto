import Foundation

/// Pure, hermetically-testable trip-context serializer for the two
/// on-device AI garnishes (`Platform/OnDeviceExtractor.swift`'s
/// `summarizeTrip`/`suggestPacking`) — renders through the SAME formatters
/// the rest of the app already uses for a plain-text trip description
/// (`ShareSummary.text`/`TripDateRangeFormat`), so the model's prompt is
/// tz-correct by construction instead of re-deriving its own date math. No
/// FoundationModels import, no `@available` gate (unlike that file) — this
/// is plain string-building any hermetic test can call directly, per that
/// file's own "do not attempt to unit-test actual model calls" rule.
enum TripPromptContext {
    /// Cap on rendered itinerary lines — mirrors `ImportContextBudget`'s
    /// "keep the on-device prompt inside the shared context window"
    /// discipline (`Features/Trip/ImportExtraction.swift`), just as a flat
    /// item count rather than a byte budget: that budget exists because a
    /// PASTE is arbitrary/untrusted length, while a trip's own item count is
    /// already bounded by ordinary trip size, so a simple ceiling is enough
    /// headroom here rather than measuring bytes of its own.
    static let itemBudget = 40

    /// Trip title/destination/dates, traveler names, and up to
    /// `itemBudget` itinerary lines (`ShareSummary.text(for:)`, in
    /// callers' own order — both call sites pass already start-sorted
    /// items, same as `TripView.items`). Shared by both "Catch me up" and
    /// packing suggestions: `existingPackingLabels` is `nil` for "Catch me
    /// up" (no packing section at all) and a — possibly empty — array for
    /// packing suggestions, whose prompt needs to tell the model what's
    /// already on the list so it can avoid repeating it. The client-side
    /// dedupe in `Features/Trip/PackingSuggestions.swift` is the real
    /// guard against a repeat; this section is just the model's own hint.
    static func render(
        trip: Trip,
        memberNames: [String],
        items: [ItineraryItem],
        existingPackingLabels: [String]? = nil
    ) -> String {
        var lines: [String] = []
        lines.append("Trip: \(trip.title)")
        if !trip.destination.isEmpty {
            lines.append("Destination: \(trip.destination)")
        }
        lines.append("Dates: \(TripDateRangeFormat.text(start: trip.startDate, end: trip.endDate))")
        if !memberNames.isEmpty {
            lines.append("Travelers: \(memberNames.joined(separator: ", "))")
        }

        if items.isEmpty {
            lines.append("Itinerary: nothing planned yet.")
        } else {
            lines.append("Itinerary:")
            for item in items.prefix(itemBudget) {
                lines.append("- \(ShareSummary.text(for: item))")
            }
        }

        if let existingPackingLabels {
            lines.append(
                existingPackingLabels.isEmpty
                    ? "Packing list so far: (empty)"
                    : "Packing list so far: \(existingPackingLabels.joined(separator: ", "))"
            )
        }

        return lines.joined(separator: "\n")
    }
}
