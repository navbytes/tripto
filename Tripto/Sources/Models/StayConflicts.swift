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

    /// Reviewer D2 (fixed): the conflict DECISION is made on each stay's
    /// REAL booked window (`decisionRange`), not on calendar-night labels —
    /// two different `.hotel` items can carry different `tz` values, and an
    /// eastward same-day handoff (checkout in a zone behind, check-in the
    /// same calendar day in a zone ahead — Lisbon->Madrid, London->Paris)
    /// puts the two zones' local midnights on opposite sides of the real
    /// gap between checkout and check-in, manufacturing a phantom sliver
    /// overlap that never happened in real time. Comparing the actual
    /// booked instants (`startsAt`/`endsAt`) asks the only question that
    /// matters — did these two bookings ever hold the same physical moment
    /// — and needs no zone conversion at all, since `Date` comparison is
    /// already zone-agnostic. The "N nights" COPY, once a conflict is
    /// confirmed, still comes from `nightRange`'s calendar-day labels
    /// exactly as before — unaffected by this fix for the overwhelming
    /// common case (both stays in the same zone, where the two methods
    /// always agree), and `max(1, ...)`-clamped for the rare
    /// confirmed-but-label-disjoint cross-zone case so the copy never reads
    /// a nonsensical "0 nights".
    private static func overlap(_ a: ItineraryItem, _ b: ItineraryItem) -> Conflict? {
        let (aDecisionStart, aDecisionEnd) = decisionRange(a)
        let (bDecisionStart, bDecisionEnd) = decisionRange(b)
        guard aDecisionStart < bDecisionEnd, bDecisionStart < aDecisionEnd else { return nil }

        let (aStart, aEnd) = nightRange(a)
        let (bStart, bEnd) = nightRange(b)
        let sharedStart = max(aStart, bStart)
        let sharedEnd = min(aEnd, bEnd)
        let sharedNights = max(
            1, ItineraryDayBucketing.dayCount(from: sharedStart, to: sharedEnd, calendar: ItineraryTimeZone.utcCalendar)
        )
        let isFull = sharedStart == aStart && sharedEnd == aEnd && sharedStart == bStart && sharedEnd == bEnd

        return Conflict(
            firstId: a.id, firstTitle: a.title, secondId: b.id, secondTitle: b.title,
            sharedNights: sharedNights, isFullOverlap: isFull
        )
    }

    /// Half-open `[start, end)` of calendar nights `item` occupies, read in
    /// its own zone (`ItineraryItem.startLocalDay`/`endLocalDay` —
    /// `ItineraryTimeZone.swift`). A missing `endsAt` is a single-night
    /// stay: `[start, start + 1)`. Feeds the "N nights" copy math above,
    /// and — via `instantRange` — `decisionRange`'s fallback path.
    private static func nightRange(_ item: ItineraryItem) -> (DayDate, DayDate) {
        let start = item.startLocalDay
        guard let end = item.endLocalDay, end > start else {
            return (start, addingOneDay(to: start))
        }
        return (start, end)
    }

    /// The midnight-expanded `[start, end)` instant interval for a stay with
    /// no usable `endsAt` — `nightRange`'s calendar-night labels resolved to
    /// local midnight in the item's OWN zone (`item.primaryTz`; hotels never
    /// have a separate arrival zone the way a flight does, so this is the
    /// one zone `startLocalDay`/`endLocalDay` were already computed
    /// against). This label-based expansion used to decide every conflict;
    /// comparing bare `DayDate` labels this way is only correct between
    /// stays that share a zone (two real IANA zones straddling the
    /// international date line — Kiritimati UTC+14, Pago Pago UTC-11 — can
    /// desync a same-looking label from actual simultaneity in BOTH
    /// directions, and even a same-day cross-zone handoff into a zone with
    /// a different midnight offset manufactures a phantom sliver), so it
    /// now survives only as `decisionRange`'s fallback for a single-night/
    /// walk-in stay with no real `endsAt` to compare instead.
    private static func instantRange(_ item: ItineraryItem) -> (Date, Date) {
        let (startDay, endDay) = nightRange(item)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = item.primaryTz
        return (startDay.asDate(calendar: calendar), endDay.asDate(calendar: calendar))
    }

    /// The interval `overlap(_:_:)` actually compares to decide yes/no.
    /// Prefers the stay's REAL booked window — `[startsAt, endsAt)` —
    /// whenever there's a genuine `endsAt` after `startsAt`: a checkout
    /// instant is real evidence of when the room actually frees up, so
    /// comparing it directly is immune to the cross-zone midnight-label
    /// mismatch `instantRange` is prone to (see its doc comment). Falls back
    /// to `[startsAt, end of its check-in night)` — the real check-in
    /// instant, paired with only `instantRange`'s midnight-expanded END —
    /// when `endsAt` is missing or not after `startsAt` (a single-night/
    /// walk-in stay with no real end instant to compare against). The START
    /// is deliberately the real `startsAt`, never `instantRange`'s
    /// midnight-of-check-in-day: starting at midnight let a same-day
    /// walk-in's fallback window reach back BEFORE its own check-in, far
    /// enough to overlap another stay's same-day real checkout that
    /// happened hours earlier — a phantom overlap neither stay could
    /// physically have had (reviewer-caught regression). A mixed pair —
    /// one side a real window, the other this fallback — still compares
    /// fine: the fallback claims only `[check-in, end of its night)`, so it
    /// can never fabricate an overlap before its own check-in.
    private static func decisionRange(_ item: ItineraryItem) -> (Date, Date) {
        if let endsAt = item.endsAt, endsAt > item.startsAt {
            return (item.startsAt, endsAt)
        }
        let (_, endOfNight) = instantRange(item)
        return (item.startsAt, endOfNight)
    }

    /// Same "step a `DayDate` by one calendar day via a UTC calendar" recipe
    /// `ItineraryDayBucketing.sections` already uses for its own day-by-day
    /// walk — kept local here rather than added to `DayDate` itself, which
    /// is outside this work package's file scope. The UTC calendar itself
    /// is `ItineraryTimeZone.utcCalendar` (DRY L2), not rebuilt here.
    private static func addingOneDay(to day: DayDate) -> DayDate {
        let calendar = ItineraryTimeZone.utcCalendar
        guard let next = calendar.date(byAdding: .day, value: 1, to: day.asDate(calendar: calendar)) else {
            return day
        }
        return DayDate.from(next, calendar: calendar)
    }
}
