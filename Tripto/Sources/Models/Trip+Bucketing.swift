import Foundation

/// Home's Upcoming/Past segmented control plus the "in progress" pill
/// (BUILD_PLAN.md §4.1, ACCEPTANCE.md "(c)" analog for trips). `.past` is
/// its own tab; `.upcoming` and `.inProgress` both live under the
/// "Upcoming" segment, with `.inProgress` sorting to the top.
enum TripBucket: Equatable {
    case upcoming
    case inProgress
    case past

    /// Which segmented-control tab this trip belongs in.
    var isPastTab: Bool { self == .past }
}

/// Pure, deliberately calendar-parameterized date math for trip bucketing —
/// no SwiftData, no `Calendar.current` baked in — so it's directly unit
/// testable at the exact boundary days (a trip ending today, starting
/// today, etc.) without depending on the test machine's time zone.
///
/// All three inputs (`startDate`, `endDate`, `today`) are normalized with
/// the *same* `calendar`, so this never mixes a UTC-anchored parse against
/// a device-local "today" — see `DayDate`'s doc comment for the bug this
/// avoids. Trip dates carry no time zone of their own (unlike
/// `ItineraryItem`, §7.4); "today" is whatever the viewer's calendar says
/// right now, wherever they are.
enum TripDateBucketing {
    /// Past = end date strictly before today (BUILD_PLAN.md §4.1). A trip
    /// ending *today* is still "in progress", not past — the boundary case
    /// this exists to get right.
    static func bucket(
        startDate: Date,
        endDate: Date,
        today: Date = .now,
        calendar: Calendar = .current
    ) -> TripBucket {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let now = calendar.startOfDay(for: today)

        if end < now { return .past }
        if start <= now { return .inProgress }
        return .upcoming
    }

    /// Days from today until the trip starts (for the "in N days" pill).
    /// Zero or negative once the trip has started.
    static func daysUntilStart(
        startDate: Date,
        today: Date = .now,
        calendar: Calendar = .current
    ) -> Int {
        let start = calendar.startOfDay(for: startDate)
        let now = calendar.startOfDay(for: today)
        return calendar.dateComponents([.day], from: now, to: start).day ?? 0
    }

    /// Inclusive day count, e.g. May 14 -> May 17 is 4 days.
    static func durationInDays(
        startDate: Date,
        endDate: Date,
        calendar: Calendar = .current
    ) -> Int {
        let start = calendar.startOfDay(for: startDate)
        let end = calendar.startOfDay(for: endDate)
        let span = calendar.dateComponents([.day], from: start, to: end).day ?? 0
        return span + 1
    }
}

extension Trip {
    func bucket(asOf today: Date = .now, calendar: Calendar = .current) -> TripBucket {
        TripDateBucketing.bucket(startDate: startDate, endDate: endDate, today: today, calendar: calendar)
    }

    func daysUntilStart(asOf today: Date = .now, calendar: Calendar = .current) -> Int {
        TripDateBucketing.daysUntilStart(startDate: startDate, today: today, calendar: calendar)
    }

    func durationInDays(calendar: Calendar = .current) -> Int {
        TripDateBucketing.durationInDays(startDate: startDate, endDate: endDate, calendar: calendar)
    }
}
