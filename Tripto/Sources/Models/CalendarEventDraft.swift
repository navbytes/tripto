import Foundation

/// Everything "Add to calendar" (BUILD_PLAN.md §4.4) needs to fill in an
/// `EKEvent` — deliberately Foundation-only (no `import EventKit`) so this
/// half is testable with no calendar permission and no `EKEventStore`
/// involved. `Features/Trip/BookingDetailView.swift` (per item) and
/// `Features/Trip/TripView.swift` (whole trip, E1 — docs/BACKLOG.md §E1)
/// are the only places that touch EventKit itself, mapping this draft onto
/// a real event; `Support/CalendarAccess.swift` is their shared permission
/// seam.
struct CalendarEventDraft: Equatable {
    var title: String
    var startDate: Date
    var endDate: Date
    /// Always `item.tz` (this milestone's brief: "EKEvent building uses
    /// item.tz") — never the arrival zone for a flight and never the
    /// device's zone. A calendar event has exactly one time zone; the
    /// departure zone is the item's "home" zone throughout its lifecycle.
    var timeZone: TimeZone
    var locationName: String?
    /// Deliberately excludes `confirmation` (this milestone's brief: "notes
    /// WITHOUT confirmation code") — Calendar is a different trust boundary
    /// than the app (shared calendars, Siri suggestions, widgets).
    var notes: String?
}

enum CalendarEventBuilder {
    static func draft(for item: ItineraryItem) -> CalendarEventDraft {
        CalendarEventDraft(
            title: item.title,
            startDate: item.startsAt,
            // A missing `ends_at` (an activity/food item with no known
            // duration) still needs a non-zero-length calendar event.
            endDate: item.endsAt ?? item.startsAt.addingTimeInterval(3600),
            timeZone: item.primaryTz,
            locationName: item.locationName.isEmpty ? nil : item.locationName,
            notes: item.notes
        )
    }
}
