import Foundation

/// Pure date-range text for the trip hero's meta row (BUILD_PLAN.md §4.2) —
/// kept view-free per the `PersonFilter`/`TimelineBuilder` convention so the
/// year rules are unit-testable without standing up `TripView`.
///
/// UX audit finding 5: the old inline formatting in `TripView` never showed
/// a year, so "Mar 14 – Mar 20" was ambiguous for any trip not in the
/// current year (and silently wrong-looking for one spanning two years).
enum TripDateRangeFormat {
    /// Visual variant (en-dash separator): both dates in `now`'s year →
    /// "Mar 14 – Mar 20" (today's rendering, unchanged for the common case);
    /// same non-current year → "Mar 14 – Mar 20, 2027" (year once, at the
    /// end); year-spanning → "Dec 28, 2026 – Jan 3, 2027" (year on both).
    static func text(start: Date, end: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        format(start: start, end: end, now: now, calendar: calendar, separator: " \u{2013} ")
    }

    /// Same rules as `text`, joined with a spoken "to" instead of the visual
    /// en-dash — VoiceOver reads punctuation like "–" as a literal
    /// fragment, not an implied connector (the fix already applied to
    /// `TripView.accessibleDateRangeText`).
    static func spokenText(start: Date, end: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        format(start: start, end: end, now: now, calendar: calendar, separator: " to ")
    }

    private static func format(start: Date, end: Date, now: Date, calendar: Calendar, separator: String) -> String {
        let startYear = calendar.component(.year, from: start)
        let endYear = calendar.component(.year, from: end)
        let nowYear = calendar.component(.year, from: now)
        let startText = start.formatted(.dateTime.month(.abbreviated).day())
        let endText = end.formatted(.dateTime.month(.abbreviated).day())

        if startYear != endYear {
            return "\(startText), \(startYear)\(separator)\(endText), \(endYear)"
        }
        if startYear != nowYear {
            return "\(startText)\(separator)\(endText), \(startYear)"
        }
        return "\(startText)\(separator)\(endText)"
    }
}
