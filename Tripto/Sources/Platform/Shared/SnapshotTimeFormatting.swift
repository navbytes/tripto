import Foundation

/// Pure `(Date, TimeZone) -> String` time/zone-label formatting (DRY M1
/// #1) — the single home for both the app (`Models/ItineraryTimeZone
/// .swift`'s `timeString`/`zoneLabel`/`citySegment` forward here) and the
/// widget extension (`TodayPlanWidget.swift`, `TravelDayActivityViews
/// .swift`), which can't compile `Models/` (D6: no SwiftData/model types in
/// the extension). Lives in `Platform/Shared` (compiled into both targets,
/// `project.yml`) so a flight's departure time and zone abbreviation can
/// never read differently in the app vs. the widget/Live Activity.
public enum SnapshotTimeFormatting {
    /// Wall-clock "HH:mm" for `date` in `tz` (24-hour, locale-independent).
    public static func timeString(_ date: Date, in tz: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = tz
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// A short zone label ("EDT", "WEST"): the live abbreviation for this
    /// instant if `Foundation` has one, else the city segment of the IANA
    /// identifier — so an unusual zone never renders as nothing.
    public static func zoneLabel(for tz: TimeZone, at date: Date) -> String {
        tz.abbreviation(for: date) ?? citySegment(of: tz.identifier)
    }

    /// "Europe/Lisbon" -> "Lisbon", "America/New_York" -> "New York". Falls
    /// back to the raw identifier for the rare zone with no `/` (e.g. "UTC").
    public static func citySegment(of identifier: String) -> String {
        guard let last = identifier.split(separator: "/").last else { return identifier }
        return last.replacingOccurrences(of: "_", with: " ")
    }
}
