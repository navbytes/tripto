#if DEBUG
import Foundation
import SwiftData

/// Home's DEBUG "Seed demo trip" action — a 14-day, ~40-item trip used for
/// perf and screenshot passes on the M2 timeline. Deliberately includes the
/// exact ACCEPTANCE.md "(a)" JFK→LIS flight (2026-05-14 08:20
/// `America/New_York` → 20:15 `Europe/Lisbon`) plus a Madrid side trip and
/// the return leg, so the seeded trip alone exercises multiple tz-crossing
/// pairs, a multi-night hotel stay, and a mix of items with/without
/// confirmation codes — everything the timeline needs to render.
///
/// Writes go through the exact same path every other mutation in the app
/// uses (SwiftData insert on the main context, then `SyncEngine.enqueue`
/// per row) so this also doubles as a real end-to-end sync exercise, not
/// just local fixture data.
enum DemoSeeder {
    /// Returns the new trip's id (so callers — the DEBUG menu's toast-free
    /// button, and the verification drill's launch-argument autopilot below
    /// this file — can navigate straight to it) or `nil` if there's no
    /// signed-in user to attribute the trip to.
    @discardableResult
    @MainActor
    static func seed(modelContext: ModelContext, syncEngine: SyncEngine?, authManager: AuthManager) async -> UUID? {
        guard let userId = authManager.userId else { return nil }
        let now = Date()

        let nyTz = TimeZone(identifier: "America/New_York")!
        let lisbonTz = TimeZone(identifier: "Europe/Lisbon")!
        let madridTz = TimeZone(identifier: "Europe/Madrid")!

        var deviceCalendar = Calendar(identifier: .gregorian)
        deviceCalendar.timeZone = .current

        let tripStartDay = DayDate(year: 2026, month: 5, day: 14)
        let tripEndDay = DayDate(year: 2026, month: 5, day: 27) // 14 days inclusive

        let tripId = UUID()
        let trip = Trip(
            id: tripId, title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: tripStartDay.asDate(calendar: deviceCalendar),
            endDate: tripEndDay.asDate(calendar: deviceCalendar),
            coverGradient: "dusk", tripTypeRaw: TripType.family.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        // A *local-only* provisional organizer membership for offline role-
        // gating, exactly like the real create path (TripFormView.save) — it's
        // inserted locally but never pushed; the server's trip-creation trigger
        // seats the real organizer trip_members row (and a linked trip_profiles
        // row) when the trip inserts, and the next pull reconciles this to it.
        // The organizer's profile is therefore NOT built here — it arrives from
        // the trigger with a stable server id, which is why demo assignments/
        // packing only ever reference the non-app profiles below.
        let member = TripMember(
            id: UUID(), tripId: tripId, userId: userId, roleRaw: TripRole.organizer.rawValue, createdAt: now
        )
        // M4 family layer: two non-app profiles (BUILD_PLAN.md §3.3/§5.3) —
        // the kids/grandparents the "Just mine" filter and packing list are
        // built for, seeded the same way a real organizer would add them
        // via `ShareTripView`'s "Add someone without the app".
        let meeraProfile = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Meera (7)", avatarColor: "plum",
            linkedUserId: nil, createdAt: now
        )
        let grandmaProfile = TripProfile(
            id: UUID(), tripId: tripId, displayName: "Grandma", avatarColor: "sky",
            linkedUserId: nil, createdAt: now
        )

        var items: [ItineraryItem] = []
        items.append(contentsOf: flights(tripId: tripId, userId: userId, now: now, nyTz: nyTz, lisbonTz: lisbonTz, madridTz: madridTz))
        items.append(contentsOf: hotels(tripId: tripId, userId: userId, now: now, lisbonTz: lisbonTz, madridTz: madridTz))
        items.append(contentsOf: fillerItems(
            tripId: tripId, tripStartDay: tripStartDay, userId: userId, now: now, lisbonTz: lisbonTz, madridTz: madridTz
        ))
        // A dedicated, unambiguous kid-tagged item (BUILD_PLAN.md §5.4) —
        // clearer for the verify-drill screenshot than reaching into the
        // sprawling filler pool by fragile index/title matching.
        let napItem = familyDemoItem(tripId: tripId, userId: userId, now: now, lisbonTz: lisbonTz)
        items.append(napItem)
        // Tag two existing filler items in place — `details` is a computed
        // get/set property over the full `ItemDetails` struct
        // (`ItineraryItem+Details.swift`), so mutating just `.tags` here
        // preserves whatever address/ticketRef/etc. the filler loop already
        // set, exactly like a real edit through `AddItemSheet` would.
        let strollerItem = items.first { $0.title == "Oceanário de Lisboa" }
        strollerItem?.details.tags = [ItemTag.strollerOk.rawValue]
        let kidsMenuItem = items.first { $0.category == .food }
        kidsMenuItem?.details.tags = [ItemTag.kidsMenu.rawValue]

        // M4: item_assignees — "Just mine" needs at least one item per
        // profile so every chip has something to filter to.
        var assignees: [ItemAssignee] = [ItemAssignee(itemId: napItem.id, profileId: meeraProfile.id)]
        if let strollerItem {
            assignees.append(ItemAssignee(itemId: strollerItem.id, profileId: meeraProfile.id))
        }
        if let kidsMenuItem {
            assignees.append(ItemAssignee(itemId: kidsMenuItem.id, profileId: meeraProfile.id))
            assignees.append(ItemAssignee(itemId: kidsMenuItem.id, profileId: grandmaProfile.id))
        }
        if let outboundFlight = items.first(where: { $0.title == "TAP TP1234" }) {
            assignees.append(ItemAssignee(itemId: outboundFlight.id, profileId: grandmaProfile.id))
        }

        // M4: a dozen packing items across every group_key, some already
        // packed (for a meaningful progress bar) and some assigned. Assigned
        // only to the non-app profiles (Meera/Grandma) — the organizer's own
        // profile is trigger-created server-side (see the note above), so it
        // has no stable local id to reference until the first pull.
        let packing = packingItems(
            tripId: tripId, userId: userId, now: now, meeraId: meeraProfile.id, grandmaId: grandmaProfile.id
        )

        modelContext.insert(trip)
        modelContext.insert(member) // local-only; never enqueued (see note above)
        modelContext.insert(meeraProfile)
        modelContext.insert(grandmaProfile)
        try? modelContext.save()

        guard let syncEngine else { return tripId }
        // Push the trip first so its trigger seats the organizer server-side
        // before the non-app profiles (whose INSERT RLS requires organizer),
        // then the flush below guarantees ordering. `member` is deliberately
        // NOT pushed — the trigger owns the real organizer row.
        await syncEngine.enqueueUpsert(table: .trips, rowId: trip.id, tripId: trip.id, payload: trip.toDTO())
        await syncEngine.enqueueUpsert(table: .tripProfiles, rowId: meeraProfile.id, tripId: tripId, payload: meeraProfile.toDTO())
        await syncEngine.enqueueUpsert(table: .tripProfiles, rowId: grandmaProfile.id, tripId: tripId, payload: grandmaProfile.toDTO())
        // `item_assignees`/`packing_items` below FK-reference both
        // `trip_profiles.id` and (for assignees) `itinerary_items.id` — an
        // explicit synchronous flush per phase, rather than trusting the
        // debounced queue's FIFO-by-`createdAt` ordering across a burst of
        // ~70 same-instant enqueues, so a same-batch sibling row is
        // guaranteed to exist server-side before anything references it.
        // DEBUG-only seeding; `flushPush()` is the same push the debounced
        // timer would eventually call, just awaited synchronously here.
        await syncEngine.flushPush()

        for item in items { modelContext.insert(item) }
        try? modelContext.save()
        for item in items {
            await syncEngine.enqueueUpsert(table: .itineraryItems, rowId: item.id, tripId: tripId, payload: item.toDTO())
        }
        await syncEngine.flushPush()

        for assignee in assignees { modelContext.insert(assignee) }
        for packingItem in packing { modelContext.insert(packingItem) }
        try? modelContext.save()
        for assignee in assignees {
            await syncEngine.enqueueUpsert(table: .itemAssignees, rowId: assignee.id, tripId: tripId, payload: assignee.toDTO())
        }
        for packingItem in packing {
            await syncEngine.enqueueUpsert(table: .packingItems, rowId: packingItem.id, tripId: tripId, payload: packingItem.toDTO())
        }
        await syncEngine.flushPush()
        return tripId
    }

    // MARK: - M4 family layer (non-app profiles, item_assignees, packing)

    /// One clean, unambiguous nap-tagged activity assigned to the (non-app)
    /// "Meera" profile — see the doc comment where this is called.
    private static func familyDemoItem(tripId: UUID, userId: UUID, now: Date, lisbonTz: TimeZone) -> ItineraryItem {
        var lisbonCalendar = Calendar(identifier: .gregorian)
        lisbonCalendar.timeZone = lisbonTz
        var details = ItemDetails.empty
        details.tags = [ItemTag.nap.rawValue]
        return makeItem(
            tripId: tripId, category: .activity, title: "Quiet time",
            startsAt: instant(2026, 5, 15, 15, 0, calendar: lisbonCalendar), endsAt: nil,
            tz: lisbonTz.identifier, locationName: "Memmo Alfama, Lisbon", confirmation: nil,
            details: details, userId: userId, now: now
        )
    }

    private static func packingItems(
        tripId: UUID, userId: UUID, now: Date, meeraId: UUID, grandmaId: UUID
    ) -> [PackingItem] {
        struct Draft {
            let label: String
            let group: PackingGroupKey
            let assignee: UUID?
            let isDone: Bool
        }
        let drafts: [Draft] = [
            // Unassigned, not the organizer's own profile — see the doc
            // comment where this function is called.
            Draft(label: "Passports (all 5)", group: .documents, assignee: nil, isDone: true),
            Draft(label: "Travel insurance printout", group: .documents, assignee: nil, isDone: true),
            Draft(label: "Boarding passes", group: .documents, assignee: nil, isDone: false),
            Draft(label: "Meera\u{2019}s car seat", group: .kids, assignee: meeraId, isDone: false),
            Draft(label: "Stroller (compact)", group: .kids, assignee: meeraId, isDone: false),
            Draft(label: "Snacks & activities for the flight", group: .kids, assignee: nil, isDone: true),
            Draft(label: "Universal power adapters \u{d7}3", group: .shared, assignee: nil, isDone: false),
            Draft(label: "Sunscreen (family size)", group: .shared, assignee: grandmaId, isDone: true),
            Draft(label: "First-aid kit", group: .shared, assignee: nil, isDone: false),
            Draft(label: "Rain jackets", group: .clothing, assignee: nil, isDone: false),
            Draft(label: "Swimwear", group: .clothing, assignee: grandmaId, isDone: true),
            Draft(label: "Portable phone charger", group: .custom, assignee: nil, isDone: false),
        ]
        return drafts.map { draft in
            PackingItem(
                id: UUID(), tripId: tripId, label: draft.label, groupKeyRaw: draft.group.rawValue,
                assigneeProfileId: draft.assignee, isDone: draft.isDone, createdBy: userId,
                createdAt: now, updatedAt: now, updatedBy: nil
            )
        }
    }

    // MARK: - Named items (ACCEPTANCE.md's exact flight, tz-crossing legs, multi-night stays)

    private static func flights(
        tripId: UUID, userId: UUID, now: Date, nyTz: TimeZone, lisbonTz: TimeZone, madridTz: TimeZone
    ) -> [ItineraryItem] {
        var nyCalendar = Calendar(identifier: .gregorian); nyCalendar.timeZone = nyTz
        var lisbonCalendar = Calendar(identifier: .gregorian); lisbonCalendar.timeZone = lisbonTz
        var madridCalendar = Calendar(identifier: .gregorian); madridCalendar.timeZone = madridTz

        // Outbound — ACCEPTANCE.md "(a)" Case A1, verbatim.
        var outbound = ItemDetails.empty
        outbound.airline = "TAP Air Portugal"; outbound.flightNo = "TP1234"
        outbound.fromIATA = "JFK"; outbound.toIATA = "LIS"
        outbound.seat = "14C"; outbound.terminal = "1"; outbound.gate = "22"
        outbound.arrivalTz = lisbonTz.identifier
        let outboundFlight = makeItem(
            tripId: tripId, category: .flight, title: "TAP TP1234",
            startsAt: instant(2026, 5, 14, 8, 20, calendar: nyCalendar),
            endsAt: instant(2026, 5, 14, 20, 15, calendar: lisbonCalendar),
            tz: nyTz.identifier, locationName: "JFK", confirmation: "QK7P2M",
            details: outbound, userId: userId, now: now
        )

        // Lisbon → Madrid side trip.
        var toMadrid = ItemDetails.empty
        toMadrid.airline = "Iberia"; toMadrid.flightNo = "IB3411"
        toMadrid.fromIATA = "LIS"; toMadrid.toIATA = "MAD"; toMadrid.seat = "9A"
        toMadrid.arrivalTz = madridTz.identifier
        let toMadridFlight = makeItem(
            tripId: tripId, category: .flight, title: "Iberia IB3411",
            startsAt: instant(2026, 5, 21, 9, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 21, 11, 40, calendar: madridCalendar),
            tz: lisbonTz.identifier, locationName: "LIS", confirmation: "MAD4471",
            details: toMadrid, userId: userId, now: now
        )

        // Madrid → Lisbon return leg.
        var toLisbon = ItemDetails.empty
        toLisbon.airline = "Iberia"; toLisbon.flightNo = "IB3418"
        toLisbon.fromIATA = "MAD"; toLisbon.toIATA = "LIS"; toLisbon.seat = "9A"
        toLisbon.arrivalTz = lisbonTz.identifier
        let toLisbonFlight = makeItem(
            tripId: tripId, category: .flight, title: "Iberia IB3418",
            startsAt: instant(2026, 5, 23, 18, 0, calendar: madridCalendar),
            endsAt: instant(2026, 5, 23, 18, 45, calendar: lisbonCalendar),
            tz: madridTz.identifier, locationName: "MAD", confirmation: "LIS9982",
            details: toLisbon, userId: userId, now: now
        )

        // Return — westbound "go back" crossing (ACCEPTANCE.md "(a)" chip math, opposite direction).
        var homeward = ItemDetails.empty
        homeward.airline = "TAP Air Portugal"; homeward.flightNo = "TP1235"
        homeward.fromIATA = "LIS"; homeward.toIATA = "JFK"
        homeward.seat = "12A"; homeward.terminal = "1"
        homeward.arrivalTz = nyTz.identifier
        let homewardFlight = makeItem(
            tripId: tripId, category: .flight, title: "TAP TP1235",
            startsAt: instant(2026, 5, 27, 11, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 27, 14, 25, calendar: nyCalendar),
            tz: lisbonTz.identifier, locationName: "LIS", confirmation: "AA2201",
            details: homeward, userId: userId, now: now
        )

        return [outboundFlight, toMadridFlight, toLisbonFlight, homewardFlight]
    }

    private static func hotels(
        tripId: UUID, userId: UUID, now: Date, lisbonTz: TimeZone, madridTz: TimeZone
    ) -> [ItineraryItem] {
        var lisbonCalendar = Calendar(identifier: .gregorian); lisbonCalendar.timeZone = lisbonTz
        var madridCalendar = Calendar(identifier: .gregorian); madridCalendar.timeZone = madridTz

        var room1 = ItemDetails.empty; room1.room = "412"
        let hotel1 = makeItem(
            tripId: tripId, category: .hotel, title: "Memmo Alfama",
            startsAt: instant(2026, 5, 14, 16, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 17, 11, 0, calendar: lisbonCalendar),
            tz: lisbonTz.identifier, locationName: "Alfama, Lisbon", confirmation: "HTL-88213",
            details: room1, userId: userId, now: now
        )

        // No confirmation on this one — exercises "items without confirmations".
        var room2 = ItemDetails.empty; room2.room = "205"
        let hotel2 = makeItem(
            tripId: tripId, category: .hotel, title: "LX Boutique Hotel",
            startsAt: instant(2026, 5, 17, 15, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 21, 11, 0, calendar: lisbonCalendar),
            tz: lisbonTz.identifier, locationName: "Alcântara, Lisbon", confirmation: nil,
            details: room2, userId: userId, now: now
        )

        var room3 = ItemDetails.empty; room3.room = "1102"
        let hotel3 = makeItem(
            tripId: tripId, category: .hotel, title: "Gran Meliá Palacio de los Duques",
            startsAt: instant(2026, 5, 21, 15, 0, calendar: madridCalendar),
            endsAt: instant(2026, 5, 23, 11, 0, calendar: madridCalendar),
            tz: madridTz.identifier, locationName: "Centro, Madrid", confirmation: "MAD-77120",
            details: room3, userId: userId, now: now
        )

        var room4 = ItemDetails.empty; room4.room = "308"
        let hotel4 = makeItem(
            tripId: tripId, category: .hotel, title: "Memmo Alfama",
            startsAt: instant(2026, 5, 23, 19, 0, calendar: lisbonCalendar),
            endsAt: instant(2026, 5, 27, 11, 0, calendar: lisbonCalendar),
            tz: lisbonTz.identifier, locationName: "Alfama, Lisbon", confirmation: nil,
            details: room4, userId: userId, now: now
        )

        return [hotel1, hotel2, hotel3, hotel4]
    }

    // MARK: - Filler activities/food (spread across the trip's remaining days)

    private static let samplePlaces: [(title: String, location: String, category: ItemCategory)] = [
        ("Belém Tower", "Belém, Lisbon", .activity),
        ("Pastéis de Belém", "Belém, Lisbon", .food),
        ("LX Factory", "Alcântara, Lisbon", .activity),
        ("Time Out Market", "Cais do Sodré, Lisbon", .food),
        ("Tram 28 ride", "Graça, Lisbon", .activity),
        ("Cervejaria Ramiro", "Intendente, Lisbon", .food),
        ("São Jorge Castle", "Alfama, Lisbon", .activity),
        ("Pink Street night out", "Cais do Sodré, Lisbon", .food),
        ("Oceanário de Lisboa", "Parque das Nações, Lisbon", .activity),
        ("Ginjinha tasting", "Rossio, Lisbon", .food),
        ("Sintra day trip", "Sintra", .activity),
        ("Fado night", "Alfama, Lisbon", .food),
        ("Museu Nacional do Azulejo", "Xabregas, Lisbon", .activity),
        ("Mercado da Ribeira", "Cais do Sodré, Lisbon", .food),
        ("Prado Museum", "Retiro, Madrid", .activity),
        ("Mercado de San Miguel", "Centro, Madrid", .food),
        ("Retiro Park", "Retiro, Madrid", .activity),
        ("Botín — world's oldest restaurant", "Centro, Madrid", .food),
    ]

    private static func fillerItems(
        tripId: UUID, tripStartDay: DayDate, userId: UUID, now: Date, lisbonTz: TimeZone, madridTz: TimeZone
    ) -> [ItineraryItem] {
        // dayOffset from trip start (day 0 = May 14); Madrid days (7, 8) use
        // Europe/Madrid, everything else Europe/Lisbon — matching the
        // Madrid side trip's own dates above. Per-day hour lists (rather
        // than one fixed [9, 13, 19] for every day) so a travel day's
        // filler doesn't overlap a flight that hasn't landed yet: day 0's
        // single item sits after the evening arrival, and day 7's two
        // items sit after the ~11:40 Madrid landing.
        let schedule: [(dayOffset: Int, count: Int, hours: [Int])] = [
            (0, 1, [21]),
            (1, 3, [9, 13, 19]), (2, 3, [9, 13, 19]), (3, 3, [9, 13, 19]),
            (4, 3, [9, 13, 19]), (5, 3, [9, 13, 19]), (6, 3, [9, 13, 19]),
            (7, 2, [14, 20]),
            (9, 3, [9, 13, 19]), (10, 3, [9, 13, 19]), (11, 3, [9, 13, 19]), (12, 3, [9, 13, 19]),
            (13, 1, [9]),
        ]
        var items: [ItineraryItem] = []
        var poolIndex = 0

        for (dayOffset, count, hours) in schedule {
            let madridDay = dayOffset == 7 || dayOffset == 8
            let tz = madridDay ? madridTz : lisbonTz
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = tz

            for slot in 0..<count {
                let place = samplePlaces[poolIndex % samplePlaces.count]
                let hour = hours[slot % hours.count]
                let startsAt = dateAt(daysAfter: dayOffset, hour: hour, minute: 0, calendar: calendar, tripStartDay: tripStartDay)

                var details = ItemDetails.empty
                var confirmation: String?
                if place.category == .activity {
                    details.address = place.location
                    // Roughly half of activities carry a ticket reference —
                    // exercises "with/without confirmations" in the seed.
                    if poolIndex.isMultiple(of: 2) {
                        let ref = "TKT-\(1000 + poolIndex)"
                        details.ticketRef = ref
                        confirmation = ref
                    }
                } else {
                    details.address = place.location
                    details.partySize = 4
                    details.reservationName = "Naveen"
                    // Food never carries a confirmation code (matches
                    // AddItemSheet's own food form, which has no
                    // confirmation field).
                }

                items.append(makeItem(
                    tripId: tripId, category: place.category, title: place.title,
                    startsAt: startsAt, endsAt: nil, tz: tz.identifier, locationName: place.location,
                    confirmation: confirmation, details: details, userId: userId, now: now
                ))
                poolIndex += 1
            }
        }
        return items
    }

    // MARK: - Helpers

    private static func makeItem(
        tripId: UUID, category: ItemCategory, title: String, startsAt: Date, endsAt: Date?, tz: String,
        locationName: String, confirmation: String?, details: ItemDetails, userId: UUID, now: Date
    ) -> ItineraryItem {
        let item = ItineraryItem(
            id: UUID(), tripId: tripId, categoryRaw: category.rawValue, title: title,
            startsAt: startsAt, endsAt: endsAt, tz: tz, locationName: locationName,
            locationLat: nil, locationLng: nil, confirmation: confirmation, notes: nil,
            detailsJSON: "{}", statusRaw: ItemStatus.confirmed.rawValue, createdBy: userId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
        item.details = details
        return item
    }

    private static func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute
        return calendar.date(from: components) ?? .now
    }

    private static func dateAt(daysAfter dayOffset: Int, hour: Int, minute: Int, calendar: Calendar, tripStartDay: DayDate) -> Date {
        let base = tripStartDay.asDate(calendar: calendar)
        let shifted = calendar.date(byAdding: .day, value: dayOffset, to: base) ?? base
        var components = calendar.dateComponents([.year, .month, .day], from: shifted)
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components) ?? shifted
    }
}
#endif
