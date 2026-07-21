import Foundation
import SwiftData

// App-intents deepening (`.claude/company/app-intents/BRIEF.md`): every
// dialog/selection/lookup decision `AddToPackingIntent`/`ConfirmationCodeIntent`
// and their entity queries (`Intents.swift`) can make, as plain functions —
// same discipline as `NextUpDialog` (`Intents.swift`'s own doc comment):
// no `AppIntent`/`IntentDialog`/Siri machinery here, so every branch is
// directly unit-testable.

// MARK: - AddToPackingIntent

enum AddToPackingDialog {
    static let emptyLabelMessage = "Tell me what to add to your packing list."
    static let signedOutMessage = "You\u{2019}re signed out of Tripto \u{2014} sign in, then try again."
    static let noTripMessage = "Add a trip in Tripto first, then ask again."

    /// The same trim-then-empty-check `PackingItem.insert` itself applies
    /// (`Models/PackingItem.swift`) — reimplemented here (not called
    /// through `PackingItem.insert`, which needs a live `ModelContext`) so
    /// the "nothing to add" branch is answerable, and testable, before
    /// SwiftData enters the picture at all.
    static func validatedLabel(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func confirmation(item: String, tripTitle: String) -> String {
        "Added \(item) to \(tripTitle)\u{2019}s packing list."
    }
}

/// "In-progress else next upcoming" (BRIEF decision) — the same selection
/// rule `SyncStore.buildSnapshot`'s own `focusTrip` uses (`Data/SyncStore+
/// Snapshot.swift`), reimplemented here over `[SnapshotTrip]` (all a
/// glanceable surface, §D6, ever has to select over) rather than `[Trip]`,
/// and self-contained: it re-derives "in progress"/"upcoming" itself
/// (`TripDateBucketing`, the same pure date math `NextUpDialog` already
/// reuses) instead of trusting the caller to have pre-sorted/pre-filtered
/// `trips`, so it stays correct even if ever called with something other
/// than `TripSnapshot.trips`'s own "soonest-first, no past trips" set.
enum FocusTripSelection {
    static func focusTrip(in trips: [SnapshotTrip], now: Date = .now, calendar: Calendar = .current) -> SnapshotTrip? {
        if let inProgress = trips.first(where: { bucket($0, now: now, calendar: calendar) == .inProgress }) {
            return inProgress
        }
        return trips
            .filter { bucket($0, now: now, calendar: calendar) == .upcoming }
            .min { $0.startDate < $1.startDate }
    }

    private static func bucket(_ trip: SnapshotTrip, now: Date, calendar: Calendar) -> TripBucket {
        TripDateBucketing.bucket(startDate: trip.startDate, endDate: trip.endDate, today: now, calendar: calendar)
    }
}

// MARK: - ConfirmationCodeIntent

/// `ConfirmationCodeIntent`'s one SwiftData touch, deliberately isolated to
/// this single function: a confirmation code must never reach the
/// snapshot, a log line, a Shortcuts donation, or a Spotlight attribute
/// (BRIEF decision) — this reads it fresh from SwiftData at perform-time
/// and nowhere else does. `nil` covers "no item with this id" and "item has
/// no code" identically; `ConfirmationCodeDialog` answers both the same
/// way, so callers never need to tell them apart.
enum ConfirmationCodeLookup {
    static func code(forItemId itemId: UUID, in context: ModelContext) -> String? {
        let descriptor = FetchDescriptor<ItineraryItem>(predicate: #Predicate { $0.id == itemId })
        guard let item = try? context.fetch(descriptor).first else { return nil }
        let trimmed = item.confirmation?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}

enum ConfirmationCodeDialog {
    static func build(title: String, code: String?) -> String {
        guard let code else {
            return "No code saved for \(title)."
        }
        return "\(title)\u{2019}s confirmation code is \(code)."
    }
}

// MARK: - Entity options (TripEntity / BookingEntity, see Intents.swift)

/// Snapshot -> entity-option mapping for `TripEntityQuery` (`Intents.swift`)
/// — pulled out as a plain function so it's testable against a fixture
/// `TripSnapshot` with no `EntityQuery`/Siri machinery involved.
enum TripEntityOptions {
    static func options(from snapshot: TripSnapshot?) -> [TripEntity] {
        (snapshot?.trips ?? []).map { TripEntity(id: $0.id, title: $0.title) }
    }
}

/// Snapshot -> entity-option mapping for `BookingEntityQuery` (`Intents.swift`).
enum BookingEntityOptions {
    /// The only categories a snapshot item can answer "what's my
    /// confirmation code" for (BRIEF decision). Mirrors the flight/hotel/
    /// transport half of `ItineraryItem.isBooking` — that property's
    /// activity/food half ("does it carry a reservation marker") can't be
    /// replicated here: it reads `confirmation`/`details.ticketRef`,
    /// neither of which the snapshot carries by design (`TripSnapshot`'s
    /// own doc comment).
    static let bookingCategories: Set<SnapshotItem.Category> = [.flight, .hotel, .transport]

    static func options(from snapshot: TripSnapshot?) -> [BookingEntity] {
        (snapshot?.focusTripItems ?? [])
            .filter { bookingCategories.contains($0.category) }
            .map { BookingEntity(id: $0.id, title: $0.title) }
    }
}
