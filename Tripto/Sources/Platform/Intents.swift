import AppIntents
import Foundation

/// PLAN-signature-layer.md §D7: "when's my next flight/trip" answered via
/// Siri/Shortcuts WITHOUT foregrounding the app. Reads the same app-group
/// `TripSnapshot` the widgets read (§D6) — no `ModelContainer` spin-up in a
/// background app launch, one shared glanceable truth, same sanitization
/// guarantees. `openAppWhenRun = false` is the whole point: a spoken/text
/// dialog answers the question in place.
struct NextUpIntent: AppIntent {
    static let title: LocalizedStringResource = "Next trip"
    static let description = IntentDescription("Hear what's next on your Tripto itinerary.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: IntentDialog(stringLiteral: NextUpDialog.build(snapshot: TripSnapshot.load())))
    }
}

/// One intent, one shortcut, fixed (non-parameterized) phrases — research §3:
/// a phrase built around an `AppEntity` parameter stays invisible in
/// Shortcuts/Siri until the app has launched once and registered its
/// entities via `updateAppShortcutParameters()`; these fixed phrases are
/// discoverable the moment the app is installed (spot-checked live for
/// W2-C — see the handoff for the verdict). Deliberately no `AppEntity`/
/// per-trip phrase — out of scope per §D7 and research §3.
struct TriptoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextUpIntent(),
            phrases: [
                "When\u{2019}s my next flight in \(.applicationName)?",
                "What\u{2019}s my next trip in \(.applicationName)?",
                "Where am I going next in \(.applicationName)?",
            ],
            shortTitle: "Next trip",
            systemImageName: "airplane.departure"
        )
    }
}

// MARK: - Dialog builder

/// Pure `TripSnapshot -> String` builder (§D7: "the dialog builder becomes a
/// pure function over `TripSnapshot`, directly unit-testable") — no
/// `AppIntent`/`IntentDialog` machinery here, so `NextUpDialogTests` can
/// exercise every branch without standing up an intent. Reuses the app's
/// existing pure date/tz helpers (`TripDateBucketing`, `TripCard.
/// startDateText`, `ItineraryTimeZone`) so the spoken answer stays in sync
/// with what the app itself shows for the same trip/flight.
enum NextUpDialog {
    /// A flight only counts as "next up" inside this window — an explicit
    /// threshold, same discipline as the Live Activity's own 8h start-window
    /// (§D6), not a vibe.
    static let flightLookahead: TimeInterval = 48 * 3600

    static let noTripsMessage = "No upcoming trips yet \u{2014} open Tripto to plan one."

    static func build(snapshot: TripSnapshot?, now: Date = .now, calendar: Calendar = .current) -> String {
        guard let snapshot, let focusTrip = snapshot.trips.first else {
            return noTripsMessage
        }
        if let flight = nextFlight(in: snapshot.focusTripItems, after: now) {
            return flightText(flight, now: now, calendar: calendar)
        }
        return tripText(focusTrip, now: now, calendar: calendar)
    }

    /// Earliest upcoming flight starting within `flightLookahead` —
    /// `focusTripItems` is already scoped to one trip (the focus trip, §D6),
    /// so no trip-id filter is needed here.
    private static func nextFlight(in items: [SnapshotItem], after now: Date) -> SnapshotItem? {
        items
            .filter { $0.category == .flight && $0.startsAt > now && $0.startsAt <= now.addingTimeInterval(flightLookahead) }
            .min { $0.startsAt < $1.startsAt }
    }

    /// §7.4 discipline: the flight's own local time + zone label, never the
    /// device's zone.
    private static func flightText(_ flight: SnapshotItem, now: Date, calendar: Calendar) -> String {
        let tz = TimeZone(identifier: flight.tz) ?? .current
        let time = ItineraryTimeZone.timeString(flight.startsAt, in: tz)
        let zone = ItineraryTimeZone.zoneLabel(for: tz, at: flight.startsAt)
        let day = dayWord(for: flight.startsAt, asOf: now, calendar: calendar)
        var subject = flight.flightNo.map { "Flight \($0)" } ?? flight.title
        if let to = flight.toIATA { subject += " to \(to)" }
        return "\(subject) departs \(day) at \(time) \(zone)."
    }

    private static func tripText(_ trip: SnapshotTrip, now: Date, calendar: Calendar) -> String {
        switch TripDateBucketing.bucket(startDate: trip.startDate, endDate: trip.endDate, today: now, calendar: calendar) {
        case .inProgress:
            let through = TripCard.startDateText(for: trip.endDate, asOf: now, calendar: calendar)
            return "You\u{2019}re in \(trip.title) through \(through)."
        case .upcoming:
            let start = TripCard.startDateText(for: trip.startDate, asOf: now, calendar: calendar)
            let days = TripDateBucketing.daysUntilStart(startDate: trip.startDate, today: now, calendar: calendar)
            return "Your next trip is \(trip.title) \u{2014} starts \(start), in \(days) day\(days == 1 ? "" : "s")."
        case .past:
            // `SyncStore.buildSnapshot` only ever writes upcoming/in-progress
            // trips, but `now` here is evaluated at call time, not write
            // time (`TripSnapshot`'s own doc comment: consumers compute
            // "now" themselves so the file never goes stale) — a trip that
            // was in-progress when the snapshot was generated can have
            // quietly ended by the time someone asks Siri. Reads the same as
            // truly having nothing upcoming rather than announcing a trip
            // that's already over.
            return noTripsMessage
        }
    }

    /// "today"/"tomorrow"/weekday name, compared in the *device's* current
    /// calendar day — matches how the rest of the app frames "today" (D4's
    /// `DayDate.from(.now)`, `TripCard.daysUntilStart`), not the flight's
    /// own departure/arrival zone.
    private static func dayWord(for date: Date, asOf now: Date, calendar: Calendar) -> String {
        let dayDiff = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: date)
        ).day ?? 0
        switch dayDiff {
        case 0: return "today"
        case 1: return "tomorrow"
        default: return date.formatted(.dateTime.weekday(.wide))
        }
    }
}
