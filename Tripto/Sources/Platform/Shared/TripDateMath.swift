import Foundation

/// Pure trip start/end date math (DRY M1 #2) — shared by the app
/// (`Models/Trip+Bucketing.swift`'s `TripDateBucketing.bucket` calls in for
/// its "in progress" check) and the widget extension (`SnapshotTrip`'s own
/// extension, `NextTripWidget.swift`), which can't compile `Models/` (D6).
/// `Date`/`Calendar` ins and outs only — no `Trip`/`SnapshotTrip` coupling —
/// so a trip's "in N days"/"in progress" pill can never disagree between
/// the app and the widget/Live Activity.
public enum TripDateMath {
    /// Whether `date` falls within `[startDate, endDate]`, all three
    /// compared as `calendar.startOfDay` — the boundary is inclusive on
    /// both ends (a trip starting or ending today is still "in progress").
    public static func isInProgress(startDate: Date, endDate: Date, asOf date: Date, calendar: Calendar) -> Bool {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let today = calendar.startOfDay(for: date)
        return start <= today && today <= end
    }

    /// Days from `today` until `startDate` (for the "in N days" pill).
    /// Zero or negative once the trip has started.
    public static func daysUntilStart(startDate: Date, today: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: startDate)
        let now = calendar.startOfDay(for: today)
        return calendar.dateComponents([.day], from: now, to: start).day ?? 0
    }
}
