import Foundation

/// Stay-overlap detection (docs/UX_REDESIGN_ROADMAP.md Phase 2, P2.1): two
/// hotel bookings on the same trip covering the same night(s) — almost
/// always an accidental duplicate, since an intentional multi-stop/split-
/// stay trip is out of v1 scope (CLAUDE.md, BUILD_PLAN.md §2). Pure function
/// over a trip's `.hotel` items; `ItineraryTabView` recomputes this from its
/// own live `@Query`-backed items on every render — no persistence, no
/// backend involvement, nothing to keep in sync.
enum StayConflicts {
    /// One overlapping pair, ordered `first` = the earlier-starting stay so
    /// callers (banner copy, "first offending card" scroll target) don't
    /// need their own tie-breaking rule.
    struct Conflict: Equatable {
        let firstId: UUID
        let firstTitle: String
        let secondId: UUID
        let secondTitle: String
        /// Calendar nights the two stays actually share — always >= 1 for
        /// anything in this list (see `overlap(_:_:)`).
        let sharedNights: Int
        /// True when `sharedNights` equals BOTH stays' entire length, i.e.
        /// the two bookings cover the exact same date range — the
        /// roadmap's own duplicate-booking example ("Two stays overlap all
        /// 6 nights"). False for a partial/nested overlap, where only some
        /// of one or both stays' nights collide.
        let isFullOverlap: Bool
    }

    /// Every overlapping pair among `items`' `.hotel` entries.
    ///
    /// ponytail: O(n^2) over the trip's own stay count — a trip has a
    /// handful of hotel bookings, not thousands; revisit only if that
    /// assumption stops holding.
    static func conflicts(in items: [ItineraryItem]) -> [Conflict] {
        let stays = items.filter { $0.category == .hotel }.sorted { $0.startsAt < $1.startsAt }
        guard stays.count > 1 else { return [] }

        var found: [Conflict] = []
        for i in stays.indices {
            for j in stays.indices where j > i {
                if let conflict = overlap(stays[i], stays[j]) {
                    found.append(conflict)
                }
            }
        }
        return found
    }

    /// Item ids implicated in at least one conflict — `ItineraryTabView`
    /// reads this to decide whether a given check-in card gets the rose
    /// flag line.
    static func flaggedItemIds(in conflicts: [Conflict]) -> Set<UUID> {
        Set(conflicts.flatMap { [$0.firstId, $0.secondId] })
    }

    /// The other hotel's name for `itemId`'s own flag line ("Overlaps
    /// {other}, same nights") — the first conflict naming `itemId`, so a
    /// stay caught up in more than one overlap still reads one clear
    /// sentence instead of listing every stay it clashes with.
    static func otherHotelName(for itemId: UUID, in conflicts: [Conflict]) -> String? {
        for conflict in conflicts {
            if conflict.firstId == itemId { return conflict.secondTitle }
            if conflict.secondId == itemId { return conflict.firstTitle }
        }
        return nil
    }

    /// The banner's headline (roadmap: "headline like 'Two stays overlap
    /// all 6 nights'") — built off the first conflict only. A trip with
    /// more than one overlapping pair is already a rare edge case this
    /// banner doesn't try to enumerate exhaustively; "Review stays" still
    /// scrolls to the first offending card regardless.
    static func headline(for conflict: Conflict) -> String {
        let nights = "\(conflict.sharedNights) night\(conflict.sharedNights == 1 ? "" : "s")"
        return conflict.isFullOverlap ? "Two stays overlap all \(nights)" : "Two stays overlap \(nights)"
    }

    /// The banner's body (roadmap: "body naming both hotels").
    static func body(for conflict: Conflict) -> String {
        let nights = "\(conflict.sharedNights) night\(conflict.sharedNights == 1 ? "" : "s")"
        return "\(conflict.firstTitle) and \(conflict.secondTitle) are both booked for the same \(nights). " +
            "One is probably a duplicate."
    }

    // MARK: - Pure overlap math

    /// Reviewer D2: the conflict DECISION is made on real instants
    /// (`instantRange`), not on bare calendar-day labels — two different
    /// `.hotel` items can carry different `tz` values, and comparing their
    /// `nightRange` labels directly is only valid when both stays share a
    /// zone (see `instantRange`'s doc comment for the date-line case where
    /// bare labels desync from actual physical overlap in both
    /// directions). The "N nights" COPY, once a conflict is confirmed,
    /// still comes from `nightRange`'s calendar-day labels exactly as
    /// before — unaffected by this fix for the overwhelming common case
    /// (both stays in the same zone, where the two methods always agree),
    /// and `max(1, ...)`-clamped for the rare confirmed-but-label-disjoint
    /// cross-zone case so the copy never reads a nonsensical "0 nights".
    private static func overlap(_ a: ItineraryItem, _ b: ItineraryItem) -> Conflict? {
        let (aInstantStart, aInstantEnd) = instantRange(a)
        let (bInstantStart, bInstantEnd) = instantRange(b)
        guard aInstantStart < bInstantEnd, bInstantStart < aInstantEnd else { return nil }

        let (aStart, aEnd) = nightRange(a)
        let (bStart, bEnd) = nightRange(b)
        let sharedStart = max(aStart, bStart)
        let sharedEnd = min(aEnd, bEnd)
        let sharedNights = max(1, ItineraryDayBucketing.dayCount(from: sharedStart, to: sharedEnd, calendar: utcCalendar))
        let isFull = sharedStart == aStart && sharedEnd == aEnd && sharedStart == bStart && sharedEnd == bEnd

        return Conflict(
            firstId: a.id, firstTitle: a.title, secondId: b.id, secondTitle: b.title,
            sharedNights: sharedNights, isFullOverlap: isFull
        )
    }

    /// Half-open `[start, end)` of calendar nights `item` occupies, read in
    /// its own zone (`ItineraryItem.startLocalDay`/`endLocalDay` —
    /// `ItineraryTimeZone.swift`). A missing `endsAt` is a single-night
    /// stay: `[start, start + 1)`. Feeds both `instantRange` (the actual
    /// overlap decision) and the "N nights" copy math above.
    private static func nightRange(_ item: ItineraryItem) -> (DayDate, DayDate) {
        let start = item.startLocalDay
        guard let end = item.endLocalDay, end > start else {
            return (start, addingOneDay(to: start))
        }
        return (start, end)
    }

    /// The physical `[start, end)` instant interval `item`'s stay actually
    /// occupies — `nightRange`'s calendar-night labels resolved to local
    /// midnight in the item's OWN zone (`item.primaryTz`; hotels never
    /// have a separate arrival zone the way a flight does, so this is the
    /// one zone `startLocalDay`/`endLocalDay` were already computed
    /// against). Comparing bare `DayDate` labels (as `nightRange` alone
    /// would) is only correct between stays that share a zone: two real
    /// IANA zones straddling the international date line (Kiritimati
    /// UTC+14, Pago Pago UTC-11 — a genuine 25h offset) can desync a
    /// same-looking label from actual simultaneity in BOTH directions — a
    /// real overlap whose labels don't match, and matching labels with no
    /// real overlap. Converting to genuine instants first (this function)
    /// makes "do these two stays double-book the same physical time" the
    /// literal question being asked, regardless of which zone each side is
    /// in.
    private static func instantRange(_ item: ItineraryItem) -> (Date, Date) {
        let (startDay, endDay) = nightRange(item)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = item.primaryTz
        return (startDay.asDate(calendar: calendar), endDay.asDate(calendar: calendar))
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Same "step a `DayDate` by one calendar day via a UTC calendar" recipe
    /// `ItineraryDayBucketing.sections` already uses for its own day-by-day
    /// walk — kept local here rather than added to `DayDate` itself, which
    /// is outside this work package's file scope.
    private static func addingOneDay(to day: DayDate) -> DayDate {
        let calendar = utcCalendar
        guard let next = calendar.date(byAdding: .day, value: 1, to: day.asDate(calendar: calendar)) else {
            return day
        }
        return DayDate.from(next, calendar: calendar)
    }
}
