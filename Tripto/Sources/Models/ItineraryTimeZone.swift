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
    /// Forwards to `Platform/Shared/SnapshotTimeFormatting` (DRY M1 #1) —
    /// the widget extension needs the identical formatting and can't
    /// compile `Models/`, so the one implementation lives there instead.
    static func timeString(_ date: Date, in tz: TimeZone) -> String {
        SnapshotTimeFormatting.timeString(date, in: tz)
    }

    /// A short zone label for the gutter/boarding-pass ("EDT", "WEST"): the
    /// live abbreviation for this instant if `Foundation` has one, else the
    /// city segment of the IANA identifier — the brief's explicit fallback,
    /// so an unusual zone never renders as nothing.
    static func zoneLabel(for tz: TimeZone, at date: Date = .now) -> String {
        SnapshotTimeFormatting.zoneLabel(for: tz, at: date)
    }

    /// "Europe/Lisbon" -> "Lisbon", "America/New_York" -> "New York". Falls
    /// back to the raw identifier for the rare zone with no `/` (e.g. "UTC").
    static func citySegment(of identifier: String) -> String {
        SnapshotTimeFormatting.citySegment(of: identifier)
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

    /// "Wed May 14" — a fixed POSIX-locale day label (DRY M3): the
    /// booking-detail share summary's day half (`Models/ShareSummary.swift`,
    /// the item's own zone) and the timeline's day-section header
    /// (`Features/Trip/TimelineModels.swift`, UTC — it formats a `DayDate`
    /// at UTC-midnight) both built this exact recipe; this is the one place
    /// it's built now.
    static func dayLabel(_ date: Date, in tz: TimeZone) -> String {
        posixFormatter("EEE MMM d", timeZone: tz).string(from: date)
    }

    /// One POSIX-locale `DateFormatter` construction recipe (DRY L1): fixed
    /// `format` + `timeZone`, `en_US_POSIX` locale — every fixed-format,
    /// locale-independent formatter keyed on a bare time zone is built this
    /// way.
    static func posixFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.dateFormat = format
        formatter.timeZone = timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }

    /// Same POSIX-locale recipe as `posixFormatter(_:timeZone:)`, for the
    /// one call site (`TripArchiveExporter.writeTempFile`) that needs its
    /// own `Calendar`'s identifier honored, not just a bare time zone.
    static func posixFormatter(_ format: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter
    }

    /// The UTC time zone, shared so `TimeZone(identifier: "UTC")!` isn't
    /// force-unwrapped again at every call site that needs one (DRY L2).
    static let utc = TimeZone(identifier: "UTC")!

    /// A Gregorian calendar fixed to `utc` — the canonical calendar
    /// `DayDate`'s own UTC-midnight anchor is read/written against (DRY L2).
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        return calendar
    }()
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
