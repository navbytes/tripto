import EventKit

/// The "request calendar access, get a denial toast" seam shared by both
/// EventKit call sites in Features/Trip — lifted out of
/// `BookingDetailView.addToCalendar`'s inline permission request (E1's
/// brief §2, docs/BACKLOG.md §E1) so `TripView`'s whole-trip batch export
/// doesn't re-derive it. The two call sites differ only in how much access
/// they need: the per-item add never reads the calendar back, so
/// write-only continues to suffice there (unchanged behavior/copy); the
/// batch export's idempotency check (searching for already-exported
/// events, `TripCalendarExport.shouldSkip`) does need read access, so it
/// requests full.
///
/// iOS 17 requires a level-specific Info.plist usage-description key for
/// each (`project.yml`): `NSCalendarsWriteOnlyAccessUsageDescription` for
/// `.writeOnly`, `NSCalendarsFullAccessUsageDescription` for `.full` — the
/// legacy `NSCalendarsUsageDescription` alone doesn't cover either once an
/// app links the iOS 17 SDK, which this one does (deploymentTarget 17.0).
enum CalendarAccess {
    enum Level {
        case writeOnly
        case full
    }

    static func request(_ level: Level, store: EKEventStore) async throws -> Bool {
        switch level {
        case .writeOnly: return try await store.requestWriteOnlyAccessToEvents()
        case .full: return try await store.requestFullAccessToEvents()
        }
    }

    /// Same copy `BookingDetailView`'s per-item add already showed on
    /// denial before this seam existed — unchanged.
    static let deniedMessage = "Calendar access is off. Turn it on in Settings > Tripto to add events."
}
