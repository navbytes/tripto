import Foundation

/// E2 (docs/BACKLOG.md §E2 "Duplicate trip") — clone an existing trip as a
/// template for a re-run (an annual trip, say). Pure date/strip/clone math
/// only, no `ModelContext` — same "Foundation-only, no persistence" split as
/// `TripCalendarExport.swift`, so every rule here (rebase math, the
/// details-key strip allowlist, packing reset, suggested-item exclusion) is
/// directly testable. `HomeView` is the one place that fetches the source
/// trip's rows, inserts the clones, and enqueues them — the same
/// model-insert-then-outbox-enqueue path every other write in the app uses.
enum TripDuplication {
    // MARK: - Create-mode prefill

    /// `TripFormView`'s create-mode seed for "Duplicate Trip" (design
    /// brief): same destination/country/type/cover, title suffixed " copy",
    /// dates shifted to the same DURATION starting today. The user still
    /// reviews this in the form and can change anything before saving — this
    /// is a starting point, not a silent decision.
    static func prefill(for source: Trip, today: Date = .now, calendar: Calendar = .current) -> TripFormView.Prefill {
        let start = calendar.startOfDay(for: today)
        let duration = source.durationInDays(calendar: calendar)
        let end = calendar.date(byAdding: .day, value: duration - 1, to: start) ?? start
        return TripFormView.Prefill(
            title: "\(source.title) copy",
            destination: source.destination,
            countryCode: source.countryCode,
            startDate: start,
            endDate: end,
            tripType: source.tripType,
            coverGradientKey: source.coverGradient
        )
    }

    // MARK: - Date rebasing (DST-safe: calendar/component arithmetic, never a fixed interval)

    /// Calendar-day delta between two trip start dates — both are plain
    /// wall-calendar days (`Trip.startDate`'s doc comment), so this is a
    /// component-based day count. Every cloned item's `startsAt`/`endsAt` is
    /// rebased by exactly this many days.
    static func dayDelta(from oldStart: Date, to newStart: Date, calendar: Calendar = .current) -> Int {
        calendar.dateComponents(
            [.day],
            from: calendar.startOfDay(for: oldStart),
            to: calendar.startOfDay(for: newStart)
        ).day ?? 0
    }

    /// Shifts `date` by `dayDelta` calendar days *as measured in `tz`*,
    /// preserving the wall-clock time in that zone — a 14:30 Europe/Lisbon
    /// flight rebased across a DST boundary is still 14:30 Lisbon local on
    /// the new date; the underlying UTC instant moves by however much that
    /// zone's offset changed in between. `Calendar.date(byAdding:.day...)`
    /// operates on calendar components, not a fixed 86_400s multiply, so
    /// this is DST-safe by construction — same idiom `ItemTimeCombining
    /// .combine`'s `dayOffset` handling already uses.
    static func rebase(_ date: Date, byDays dayDelta: Int, in tz: TimeZone) -> Date {
        guard dayDelta != 0 else { return date }
        var tzCalendar = Calendar(identifier: .gregorian)
        tzCalendar.timeZone = tz
        return tzCalendar.date(byAdding: .day, value: dayDelta, to: date) ?? date
    }

    // MARK: - Stale-booking-specifics strip (design brief's exact allowlist)

    /// Drops the fields specific to a past confirmation and stale on a
    /// re-run (seat/gate/terminal/ticket ref/reservation name); keeps
    /// everything that still describes the plan itself (airline/flight no/
    /// airports/arrival tz/room/address/party size/provider/drop-off/tags).
    static func strippedDetails(_ details: ItemDetails) -> ItemDetails {
        var stripped = details
        stripped.seat = nil
        stripped.terminal = nil
        stripped.gate = nil
        stripped.ticketRef = nil
        stripped.reservationName = nil
        return stripped
    }

    // MARK: - Itinerary item cloning

    /// Design brief: "Confirmed itinerary items only (never suggested)."
    static func confirmedItems(_ items: [ItineraryItem]) -> [ItineraryItem] {
        items.filter { $0.status == .confirmed }
    }

    /// One cloned item: dates rebased (see `rebase` above — `endsAt`'s zone
    /// mirrors `ItineraryItem.endLocalDay`'s own rule, a flight's end reads
    /// in its arrival zone, everything else in its own `tz`), booking
    /// specifics stripped, provenance reset to a fresh manual/confirmed row
    /// owned by whoever duplicated the trip.
    static func cloneItem(_ source: ItineraryItem, tripId: UUID, dayDelta: Int, createdBy: UUID, now: Date) -> ItineraryItem {
        let item = ItineraryItem(
            id: UUID(), tripId: tripId, categoryRaw: source.categoryRaw, title: source.title,
            startsAt: rebase(source.startsAt, byDays: dayDelta, in: source.primaryTz),
            endsAt: source.endsAt.map { rebase($0, byDays: dayDelta, in: source.effectiveTz) },
            tz: source.tz, locationName: source.locationName,
            locationLat: source.locationLat, locationLng: source.locationLng,
            // Design brief, verbatim: confirmation -> nil; source -> manual;
            // status -> confirmed (source is already confirmed —
            // `confirmedItems`/`clonedItems` below only ever hand this a
            // confirmed item — but this stays explicit rather than trusting
            // that indirectly).
            confirmation: nil, notes: source.notes,
            detailsJSON: "{}", statusRaw: ItemStatus.confirmed.rawValue, sourceRaw: ItemSource.manual.rawValue,
            createdBy: createdBy, createdAt: now, updatedAt: now, updatedBy: nil
        )
        item.details = strippedDetails(source.details)
        return item
    }

    /// `sourceItems` -> the new trip's confirmed items, rebased/stripped/
    /// reattributed. Excludes anything `status == .suggested`.
    static func clonedItems(
        from sourceItems: [ItineraryItem], newTripId: UUID, dayDelta: Int, createdBy: UUID, now: Date
    ) -> [ItineraryItem] {
        confirmedItems(sourceItems).map {
            cloneItem($0, tripId: newTripId, dayDelta: dayDelta, createdBy: createdBy, now: now)
        }
    }

    // MARK: - Packing list cloning

    /// Labels + group survive; `isDone` resets (nothing is packed yet for a
    /// trip that hasn't happened) and the assignee is dropped (a brand-new
    /// trip has no members/`TripProfile` rows yet to assign against).
    static func clonePackingItem(_ source: PackingItem, tripId: UUID, createdBy: UUID, now: Date) -> PackingItem {
        PackingItem(
            id: UUID(), tripId: tripId, label: source.label, groupKeyRaw: source.groupKeyRaw,
            assigneeProfileId: nil, isDone: false, createdBy: createdBy,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
    }

    static func clonedPackingItems(
        from sourcePacking: [PackingItem], newTripId: UUID, createdBy: UUID, now: Date
    ) -> [PackingItem] {
        sourcePacking.map { clonePackingItem($0, tripId: newTripId, createdBy: createdBy, now: now) }
    }
}
