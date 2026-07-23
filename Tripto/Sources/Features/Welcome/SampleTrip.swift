import Foundation

/// Feature A1 (adoption onboarding): a fabricated "friends getaway" —
/// `WelcomeView`'s only pre-sign-in content besides the Apple button. Every
/// value here is built in-process at first access; nothing is written to
/// disk, inserted into a `ModelContext`, or pushed over the network.
/// `Trip`/`ItineraryItem`/`PackingItem` are plain `@Model` classes that only
/// touch a store once explicitly inserted — `TestFixtures.makeTrip` and
/// every `DTORoundTripTests` case already construct them standalone the
/// same way — so this is exactly as side-effect-free as any other value type.
///
/// Deliberately a `friends` trip (not `family`, the create-flow default) —
/// this is the one place the brief wants the friend-group use case shown
/// first, alongside `TripFormView`'s lighter "friends is co-equal" nudge at
/// creation time.
enum SampleTrip {
    /// Fixed only for internal referential consistency (item `tripId`/
    /// `createdBy`) — never rendered or compared against anything real.
    private static let ownerId = UUID()

    static let trip: Trip = {
        let now = Date()
        let calendar = Calendar.current
        // ~3 weeks out — reads as "upcoming" (TripCard's "in N days" pill),
        // never "in progress"/"completed", which would look stale the one
        // moment this screen has to make a strong first impression.
        let start = calendar.date(byAdding: .day, value: 21, to: calendar.startOfDay(for: now)) ?? now
        let end = calendar.date(byAdding: .day, value: 5, to: start) ?? start
        return Trip(
            id: UUID(), title: "Costa Rica with the Crew", destination: "Costa Rica", countryCode: "CR",
            startDate: start, endDate: end, coverGradient: "moss",
            tripTypeRaw: TripType.friends.rawValue, createdBy: ownerId,
            createdAt: now, updatedAt: now, updatedBy: nil
        )
    }()

    /// Four friends — plural and varied enough that `AvatarStack` reads as a
    /// group trip at a glance, not a solo or couple's trip.
    static let people: [AvatarStack.Person] = [
        .init(id: UUID(), initial: "N", colorName: "amber", name: "Nina"),
        .init(id: UUID(), initial: "J", colorName: "moss", name: "Jae"),
        .init(id: UUID(), initial: "R", colorName: "plum", name: "Rosa"),
        .init(id: UUID(), initial: "T", colorName: "sky", name: "Tom")
    ]

    /// A flight, a stay, and two activities — never rendered through their
    /// own itinerary row views (those are wired into `ItineraryTabView`'s
    /// `NavigationLink`/router stack, which this signed-out screen has none
    /// of); only their `title`s feed `teaserText` below.
    static let items: [ItineraryItem] = {
        let tripId = trip.id
        let tz = TimeZone.current.identifier
        let dayStart = Calendar.current.startOfDay(for: trip.startDate)
        let checkIn = Calendar.current.date(byAdding: .hour, value: 15, to: dayStart) ?? trip.startDate
        let checkOut = Calendar.current.date(
            byAdding: .hour, value: 11, to: Calendar.current.startOfDay(for: trip.endDate)
        ) ?? trip.endDate

        func item(_ category: ItemCategory, _ title: String, _ startsAt: Date, _ endsAt: Date?, _ location: String) -> ItineraryItem {
            ItineraryItem(
                id: UUID(), tripId: tripId, categoryRaw: category.rawValue, title: title,
                startsAt: startsAt, endsAt: endsAt, tz: tz, locationName: location,
                locationLat: nil, locationLng: nil, confirmation: nil, notes: nil,
                detailsJSON: "{}", statusRaw: ItemStatus.confirmed.rawValue, createdBy: ownerId,
                createdAt: trip.createdAt, updatedAt: trip.createdAt, updatedBy: nil
            )
        }

        return [
            item(.flight, "Flight to San Jos\u{00E9}", trip.startDate, nil, "SJO"),
            item(.hotel, "Villa Alegre stay", checkIn, checkOut, "Santa Teresa"),
            item(.activity, "Zip-lining in Monteverde", Calendar.current.date(byAdding: .day, value: 1, to: checkIn) ?? checkIn, nil, "Monteverde"),
            item(.activity, "Sunset surf lesson", Calendar.current.date(byAdding: .day, value: 2, to: checkIn) ?? checkIn, nil, "Santa Teresa")
        ]
    }()

    static let packingItem = PackingItem(
        id: UUID(), tripId: trip.id, label: "Reef-safe sunscreen", groupKeyRaw: PackingGroupKey.shared.rawValue,
        assigneeProfileId: nil, isDone: false, createdBy: ownerId,
        createdAt: trip.createdAt, updatedAt: trip.createdAt, updatedBy: nil
    )

    /// One line under the card — real item titles read more concretely than
    /// generic marketing copy, without pulling in any of the itinerary tab's
    /// coupled row views (see `items`' own doc comment).
    static let teaserText: String = {
        (items.map(\.title) + ["Pack: \(packingItem.label)"]).joined(separator: " \u{00B7} ")
    }()
}
