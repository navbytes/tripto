import Foundation

/// Combines a date-only picker value with a time-only picker value into a
/// single instant, interpreted in a specific IANA zone — the core math
/// behind every category's contextual add-item form (this milestone's
/// brief, §4.3). Pure and calendar-parameterized like the rest of the
/// `Models` layer's date helpers.
///
/// SwiftUI's `DatePicker` hands back a full `Date`, but a "date" picker's
/// value only carries meaningful year/month/day and a "time" picker's value
/// only carries meaningful hour/minute — both read using `readingCalendar`
/// (the device's own calendar by default, since that's what the picker UI
/// itself displayed to the user), then re-anchored into `targetTz`'s own
/// calendar to produce the correct UTC instant. This is what lets a form
/// say "the user tapped 8:20 AM meaning 8:20 AM *in New York*" rather than
/// silently assuming the device's own zone.
enum ItemTimeCombining {
    static func combine(
        date: Date,
        timeOfDay: Date,
        dayOffset: Int = 0,
        targetTz: TimeZone,
        readingCalendar: Calendar = .current
    ) -> Date {
        let dateComponents = readingCalendar.dateComponents([.year, .month, .day], from: date)
        let timeComponents = readingCalendar.dateComponents([.hour, .minute], from: timeOfDay)

        var targetCalendar = Calendar(identifier: .gregorian)
        targetCalendar.timeZone = targetTz

        var combined = DateComponents()
        combined.year = dateComponents.year
        combined.month = dateComponents.month
        combined.day = dateComponents.day
        combined.hour = timeComponents.hour
        combined.minute = timeComponents.minute

        guard let base = targetCalendar.date(from: combined) else { return date }
        guard dayOffset != 0 else { return base }
        return targetCalendar.date(byAdding: .day, value: dayOffset, to: base) ?? base
    }

    /// The flight form's "+1 day" default (this milestone's brief §4.3):
    /// an arrival wall-clock earlier than the departure wall-clock suggests
    /// a red-eye/long-haul that lands the calendar day after it left. This
    /// is only ever a *default* the user can toggle off — never assumed
    /// silently once they've overridden it.
    static func suggestedArrivalDayOffset(
        departsTimeOfDay: Date,
        arrivesTimeOfDay: Date,
        readingCalendar: Calendar = .current
    ) -> Int {
        let dep = readingCalendar.dateComponents([.hour, .minute], from: departsTimeOfDay)
        let arr = readingCalendar.dateComponents([.hour, .minute], from: arrivesTimeOfDay)
        let depMinutes = (dep.hour ?? 0) * 60 + (dep.minute ?? 0)
        let arrMinutes = (arr.hour ?? 0) * 60 + (arr.minute ?? 0)
        return arrMinutes < depMinutes ? 1 : 0
    }
}
