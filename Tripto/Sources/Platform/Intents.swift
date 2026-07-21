import AppIntents
import Foundation
import Supabase
import SwiftData

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

/// App-intents deepening: "Add <item> to my packing list", writing through
/// the exact offline-first outbox path every in-app add already uses
/// (`PackingItem.insert`) — offline-safe by construction, no intent-specific
/// plumbing needed. `openAppWhenRun = false` for the same reason as
/// `NextUpIntent` above: this acts in place, no need to foreground the app —
/// `AppServices` (`Platform/AppServices.swift`) is what makes that possible
/// without SwiftUI's environment.
struct AddToPackingIntent: AppIntent {
    static let title: LocalizedStringResource = "Add to packing list"
    static let description = IntentDescription("Add an item to a trip\u{2019}s packing list.")
    static let openAppWhenRun = false

    @Parameter(title: "Item")
    var item: String

    /// `nil` resolves to the focus trip (`FocusTripSelection`, BRIEF
    /// decision: in-progress else next upcoming) — the same trip
    /// `NextUpIntent`/the Today widget already treat as "the" trip.
    @Parameter(title: "Trip")
    var trip: TripEntity?

    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$item) to my packing list") {
            \.$trip
        }
    }

    /// `@MainActor`: `ModelContainer.mainContext` (SwiftData) is
    /// main-actor-isolated — the same context every in-app write already
    /// goes through via `@Environment(\.modelContext)`, so an item Siri adds
    /// is visible immediately if the app happens to already be foregrounded.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let label = AddToPackingDialog.validatedLabel(item) else {
            return .result(dialog: IntentDialog(stringLiteral: AddToPackingDialog.emptyLabelMessage))
        }
        // `SnapshotTrip` carries no `createdBy` (§D6's deliberately minimal
        // field list), so unlike `PackingListView.addItem`'s signed-out
        // local-creator allowance, this path has no fallback identity to
        // write with and must require a real session.
        guard let userId = Supa.client.auth.currentSession?.user.id else {
            return .result(dialog: IntentDialog(stringLiteral: AddToPackingDialog.signedOutMessage))
        }
        let target: (id: UUID, title: String)?
        if let trip {
            target = (trip.id, trip.title)
        } else if let focusTrip = FocusTripSelection.focusTrip(in: TripSnapshot.load()?.trips ?? []) {
            target = (focusTrip.id, focusTrip.title)
        } else {
            target = nil
        }
        guard let target, let services = AppServices.shared else {
            return .result(dialog: IntentDialog(stringLiteral: AddToPackingDialog.noTripMessage))
        }
        PackingItem.insert(
            label: label, groupKey: .shared, assigneeProfileId: nil,
            tripId: target.id, createdBy: userId,
            modelContext: services.modelContainer.mainContext, syncEngine: services.syncEngine
        )
        return .result(dialog: IntentDialog(stringLiteral: AddToPackingDialog.confirmation(item: label, tripTitle: target.title)))
    }
}

/// App-intents deepening: "What's my confirmation code for <booking>?" — the
/// code itself is read from SwiftData at perform-time only (never the
/// snapshot, a donation, or a Spotlight attribute; see `ConfirmationCodeLookup`'s
/// doc comment) and the intent requires the device to be unlocked before it
/// runs at all, since a locked-screen Siri answer would otherwise read a
/// booking reference aloud to anyone nearby.
struct ConfirmationCodeIntent: AppIntent {
    static let title: LocalizedStringResource = "Confirmation code"
    static let description = IntentDescription("Hear the confirmation code saved for a flight, hotel, or transport booking.")
    static let openAppWhenRun = false
    static var authenticationPolicy: IntentAuthenticationPolicy { .requiresLocalDeviceAuthentication }

    @Parameter(title: "Booking")
    var booking: BookingEntity

    static var parameterSummary: some ParameterSummary {
        Summary("What\u{2019}s my confirmation code for \(\.$booking)?")
    }

    /// `@MainActor`: see `AddToPackingIntent.perform()`'s doc comment — same
    /// `ModelContainer.mainContext` reasoning, read-only here.
    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let code = AppServices.shared.flatMap { ConfirmationCodeLookup.code(forItemId: booking.id, in: $0.modelContainer.mainContext) }
        return .result(dialog: IntentDialog(stringLiteral: ConfirmationCodeDialog.build(title: booking.title, code: code)))
    }
}

/// `NextUpIntent` keeps its original fixed (non-parameterized) phrases —
/// research §3: a phrase built around an `AppEntity` parameter stays
/// invisible in Shortcuts/Siri until the app has launched once and
/// registered its entities via `updateAppShortcutParameters()`, so a fixed
/// phrase is discoverable the moment the app is installed (spot-checked
/// live for W2-C — see the handoff for the verdict). `ConfirmationCodeIntent`
/// IS entity-parameterized (`BookingEntity` below) and embeds it in its own
/// phrases; that first-launch discoverability gap is an accepted platform
/// norm for it (BRIEF decision, matches the 1.1 posture this comment
/// originally described), not a defect to work around. `AddToPackingIntent`'s
/// `item` is a plain `String`, not an `AppEntity`/`AppEnum` — the App
/// Intents metadata compiler rejects a phrase that tries to embed one (only
/// entity/enum parameters are speakable-in-phrase; a required
/// non-embeddable parameter still gets asked for conversationally once the
/// phrase itself matches), so its phrases stay fixed like `NextUpIntent`'s.
struct TriptoShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: NextUpIntent(),
            phrases: [
                "When\u{2019}s my next flight in \(.applicationName)?",
                "What\u{2019}s my next trip in \(.applicationName)?",
                "Where am I going next in \(.applicationName)?"
            ],
            shortTitle: "Next trip",
            systemImageName: "airplane.departure"
        )
        AppShortcut(
            intent: AddToPackingIntent(),
            phrases: [
                "Add to my packing list in \(.applicationName)",
                "Add a packing item in \(.applicationName)"
            ],
            shortTitle: "Add to packing list",
            systemImageName: "bag.badge.plus"
        )
        AppShortcut(
            intent: ConfirmationCodeIntent(),
            phrases: [
                "What\u{2019}s my confirmation code for \(\.$booking) in \(.applicationName)?",
                "Get my confirmation code for \(\.$booking) in \(.applicationName)"
            ],
            shortTitle: "Confirmation code",
            systemImageName: "checkmark.seal"
        )
    }
}

// MARK: - Entities

/// Options sourced from the same app-group `TripSnapshot` every glanceable
/// surface reads (§D6) — no `ModelContainer` spin-up just to list trips for
/// Siri/Shortcuts to disambiguate. See `TripEntityOptions` (`IntentSupport
/// .swift`) for the actual (testable) snapshot -> options mapping; this type
/// stays thin wiring over it, matching `EntityQuery`'s own examples.
struct TripEntity: AppEntity {
    let id: UUID
    let title: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Trip"
    static let defaultQuery = TripEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct TripEntityQuery: EntityQuery {
    func entities(for identifiers: [TripEntity.ID]) async throws -> [TripEntity] {
        TripEntityOptions.options(from: TripSnapshot.load()).filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [TripEntity] {
        TripEntityOptions.options(from: TripSnapshot.load())
    }
}

/// A flight/hotel/transport item from the focus trip (`BookingEntityOptions`,
/// `IntentSupport.swift`) — id + display title only. Never carries a
/// confirmation code (BRIEF decision: codes never leave SwiftData except at
/// `ConfirmationCodeIntent.perform()`'s own point-of-use read), so this type
/// is safe to donate/persist in a shortcut with no exposure risk.
struct BookingEntity: AppEntity {
    let id: UUID
    let title: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Booking"
    static let defaultQuery = BookingEntityQuery()

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(title)")
    }
}

struct BookingEntityQuery: EntityQuery {
    func entities(for identifiers: [BookingEntity.ID]) async throws -> [BookingEntity] {
        BookingEntityOptions.options(from: TripSnapshot.load()).filter { identifiers.contains($0.id) }
    }

    func suggestedEntities() async throws -> [BookingEntity] {
        BookingEntityOptions.options(from: TripSnapshot.load())
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
