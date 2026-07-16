import Foundation

/// Plain-text summary for the booking detail's "Share with group" action
/// (BUILD_PLAN.md §4.4). Deliberately **never** includes the confirmation
/// code or notes — the share sheet leaves the app's trust boundary (Messages
/// previews, third-party extensions), same rule as the calendar handoff and
/// the public link's sanitized payload (§7.5). Format per this milestone's
/// brief: "TAP TP1234 · JFK→LIS · Wed May 14 · departs 08:20 EDT".
enum ShareSummary {
    static func text(for item: ItineraryItem) -> String {
        let tz = item.primaryTz
        let dayText = formattedDay(item.startsAt, in: tz)
        let timeText = ItineraryTimeZone.timeString(item.startsAt, in: tz)
        let zoneText = ItineraryTimeZone.zoneLabel(for: tz, at: item.startsAt)

        switch item.category {
        case .flight:
            let details = item.details
            var parts: [String] = []
            let flightName = [details.airline, details.flightNo].compactMap { $0 }.joined(separator: " ")
            parts.append(flightName.isEmpty ? item.title : flightName)
            if let from = details.fromIATA, let to = details.toIATA {
                parts.append("\(from)→\(to)")
            }
            parts.append(dayText)
            parts.append("departs \(timeText) \(zoneText)")
            return parts.joined(separator: " · ")
        case .hotel:
            var parts = [item.title, "check-in \(dayText) \(timeText) \(zoneText)"]
            if item.stayNightCount > 0 {
                parts.append("\(item.stayNightCount) night\(item.stayNightCount == 1 ? "" : "s")")
            }
            return parts.joined(separator: " · ")
        case .activity, .food:
            var parts = [item.title, dayText, "\(timeText) \(zoneText)"]
            if !item.locationName.isEmpty {
                parts.append(item.locationName)
            }
            return parts.joined(separator: " · ")
        case .transport:
            let details = item.details
            var parts = [details.provider ?? item.title]
            if !item.locationName.isEmpty, let dropoff = details.dropoffLocation {
                parts.append("\(item.locationName)\u{2192}\(dropoff)")
            }
            parts.append(dayText)
            parts.append("pickup \(timeText) \(zoneText)")
            return parts.joined(separator: " · ")
        }
    }

    /// "Wed May 14" in the item's own zone — a fixed POSIX-locale format so
    /// the summary reads the same on every sender's device. The recipe
    /// itself is `ItineraryTimeZone.dayLabel` (DRY M3), shared with
    /// `TimelineBuilder.dayTitleText`'s own day header.
    private static func formattedDay(_ date: Date, in tz: TimeZone) -> String {
        ItineraryTimeZone.dayLabel(date, in: tz)
    }
}
