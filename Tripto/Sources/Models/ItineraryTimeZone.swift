import Foundation

/// Pure time-zone math for the itinerary timeline (BUILD_PLAN.md §7.4;
/// ACCEPTANCE.md "(a)"; this milestone's brief). Every function here is a
/// plain `(Date, TimeZone) -> X` transform with no `Calendar.current`/
/// `TimeZone.current` baked in — the *only* place a "current" zone is ever
/// assumed is `ItineraryItem.primaryTz`'s `?? .current` fallback for a
/// corrupt/unknown tz string, mirroring `TripDateBucketing`'s "no hidden
/// device dependency" discipline so tests are deterministic regardless of
/// the machine running them.
enum ItineraryTimeZone {
    /// The calendar day `date` falls on when read in `tz` — the one rule
    /// used everywhere the timeline buckets items into day sections: an
    /// item belongs to the calendar date of `starts_at` **in item.tz**, so a
    /// 23:30 Europe/Lisbon dinner stays on that Lisbon date even when the
    /// same instant is already next-day UTC.
    static func localDay(of date: Date, in tz: TimeZone) -> DayDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        return DayDate.from(date, calendar: calendar)
    }

    /// Wall-clock "HH:mm" for `date` in `tz` (24-hour, locale-independent —
    /// the gutter's time column, matching the mockup's "08:20" style).
    static func timeString(_ date: Date, in tz: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = tz
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    /// A short zone label for the gutter/boarding-pass ("EDT", "WEST"): the
    /// live abbreviation for this instant if `Foundation` has one, else the
    /// city segment of the IANA identifier — the brief's explicit fallback,
    /// so an unusual zone never renders as nothing.
    static func zoneLabel(for tz: TimeZone, at date: Date = .now) -> String {
        tz.abbreviation(for: date) ?? citySegment(of: tz.identifier)
    }

    /// "Europe/Lisbon" -> "Lisbon", "America/New_York" -> "New York". Falls
    /// back to the raw identifier for the rare zone with no `/` (e.g. "UTC").
    static func citySegment(of identifier: String) -> String {
        guard let last = identifier.split(separator: "/").last else { return identifier }
        return last.replacingOccurrences(of: "_", with: " ")
    }

    /// Whether `current`'s primary zone differs from `previous`'s
    /// *effective* zone — the single trigger both the gutter's small zone
    /// label and the rail's tz-shift chip key off (BUILD_PLAN.md §7.4
    /// gutter rule). `nil` previous (the timeline's very first item) never
    /// shows a crossing.
    static func zoneChanged(from previous: ItineraryItem?, to current: ItineraryItem) -> Bool {
        guard let previous else { return false }
        return previous.effectiveTz.identifier != current.primaryTz.identifier
    }
}

extension ItineraryItem {
    /// The item's own primary zone (`tz` — departure zone for a flight).
    /// Falls back to the device's current zone for a corrupt/unrecognized
    /// identifier rather than crashing (same defensive posture as the
    /// enum accessors in Models/Enums.swift).
    var primaryTz: TimeZone { TimeZone(identifier: tz) ?? .current }

    /// The zone a traveler is left in once this item is over — a flight's
    /// arrival zone when one is set, otherwise the item's own primary zone
    /// (this milestone's brief: "a flight's effective zone AFTER it =
    /// arrival_tz ?? tz"). This is what the *next* item's gutter/rail chip
    /// compares against to decide whether a zone crossing needs calling out.
    var effectiveTz: TimeZone {
        if category == .flight, let arrivalTzId = details.arrivalTz, let zone = TimeZone(identifier: arrivalTzId) {
            return zone
        }
        return primaryTz
    }

    /// The calendar day this item's `starts_at` belongs to, in its own tz.
    var startLocalDay: DayDate { ItineraryTimeZone.localDay(of: startsAt, in: primaryTz) }

    /// The calendar day this item's `ends_at` belongs to, in whichever zone
    /// that instant should be read in — a flight's arrival zone (defaults to
    /// its own tz absent one), or a non-flight item's own tz (there is no
    /// separate "arrival zone" concept for a stay/activity/food end time).
    /// `nil` when there is no `ends_at`.
    var endLocalDay: DayDate? {
        guard let endsAt else { return nil }
        let tz = category == .flight ? effectiveTz : primaryTz
        return ItineraryTimeZone.localDay(of: endsAt, in: tz)
    }
}
