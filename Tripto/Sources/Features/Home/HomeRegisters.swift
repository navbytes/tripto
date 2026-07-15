import Foundation

/// Pure "one list, three registers" logic (docs/UX_REDESIGN_ROADMAP.md Phase
/// 5, superseding BUILD_PLAN.md §4.1's old Upcoming/Past tabs): the
/// comparator, which register a trip renders as, and the small view-model
/// builders the "next"/"now" registers need. No SwiftUI import on purpose —
/// `HomeView`/`TripCard` own the actual rendering; this only owns the
/// branching/data logic, mirroring `HomeEmptyPlaceholder`'s house pattern so
/// it's directly unit-testable without standing up a view hierarchy.
enum HomeTripOrdering {
    /// "Ahead" — ends today or later — soonest-start first. `startDate`
    /// carries no time zone of its own (`Trip+Bucketing.swift`'s doc
    /// comment), so the sort itself needs no tz awareness; only the
    /// ahead/been *split* does (`bucket`, supplied by the caller — see
    /// `ordered(_:bucket:)`'s doc comment). A live trip's `startDate` is
    /// always `<= today`, so it sorts to position 0 for free — no special
    /// case, matching the roadmap's own "Sort rule." Sort key is
    /// `(startDate, endDate, id)`, all three ascending — `endDate` sits
    /// between `startDate` and the `id` tie-break (P6.2 reviewer finding):
    /// `startDate` alone isn't enough to guarantee adjacency for
    /// `TripMergeDetection.survivorByShellId`'s "identical dates means the
    /// pair is always adjacent" assumption — a third trip sharing only the
    /// SAME start date (a different, unrelated trip) could otherwise sort
    /// BETWEEN two trips that share both start AND end (a true duplicate
    /// pair), landing between them purely by `id` string luck. Two trips
    /// tied on `(startDate, endDate)` are always contiguous in the result
    /// (a property of sorting by a compound key), so a real duplicate pair
    /// can never be split apart by an unrelated same-start trip once
    /// `endDate` also participates. `id` remains the final tie-break
    /// (reviewer finding): `sorted(by:)` is stable, but the INPUT order
    /// (`@Query`) isn't guaranteed stable across app launches, so two
    /// identical-range trips could silently swap places from one launch to
    /// the next without an explicit, deterministic tie-break.
    static func ahead(_ trips: [Trip], bucket: (Trip) -> TripBucket) -> [Trip] {
        trips.filter { !bucket($0).isPastTab }.sorted { lhs, rhs in
            if lhs.startDate != rhs.startDate { return lhs.startDate < rhs.startDate }
            if lhs.endDate != rhs.endDate { return lhs.endDate < rhs.endDate }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    /// "Been" — already ended — most-recent-first, by `endDate` (not
    /// `startDate`: a trip that started later can still have ended first,
    /// e.g. a quick weekend booked after a longer trip already in progress).
    /// Same `id` tie-break as `ahead`, same reason.
    static func been(_ trips: [Trip], bucket: (Trip) -> TripBucket) -> [Trip] {
        trips.filter { bucket($0).isPastTab }.sorted {
            $0.endDate == $1.endDate ? $0.id.uuidString < $1.id.uuidString : $0.endDate > $1.endDate
        }
    }

    /// The one list Home renders: `ahead` then `been`. `bucket` is supplied
    /// by the caller rather than defaulted to `Trip.bucket(asOf:calendar:)`'s
    /// bare device-calendar behavior — docs/UX_REDESIGN_ROADMAP.md Phase 2's
    /// note for Phase 5: judge each trip's liveness/past against *that
    /// trip's own* `TripDateBucketing.liveTimeZone(items:)`, not the
    /// device's zone, so a trip stays "ahead" at 23:00 in Naha even once the
    /// device has already rolled over.
    static func ordered(_ trips: [Trip], bucket: (Trip) -> TripBucket) -> [Trip] {
        ahead(trips, bucket: bucket) + been(trips, bucket: bucket)
    }
}

/// The recipe `ItineraryTabView` already proved (P2.4): a trip's own start/
/// end are `DayDate` labels in the DEVICE calendar (the storage anchor —
/// `Trip.startDate`/`endDate` carry no time zone of their own), while
/// "today" is a `DayDate` label in the trip's LIVE zone
/// (`TripDateBucketing.liveTimeZone`). Comparing `DayDate`s (plain Y/M/D,
/// no residual tz) rather than feeding a raw `Date` through a *swapped*
/// `Calendar` is what matters: `TripDateBucketing.bucket(...,calendar:)`
/// reads ALL THREE of its inputs (start/end/today) through the ONE calendar
/// it's given, so passing it a live-zone calendar together with the trip's
/// own device-anchored `startDate`/`endDate` silently REINTERPRETS those
/// already-anchored instants — wrongly archiving a live trip whenever the
/// live zone sits west of the device (device in Tokyo, trip's own items all
/// in Honolulu, say). This is the one shared helper `HomeView.bucket(for:)`
/// and `HomeTodayPanel.make` both route through, so the two can't drift
/// apart on how "today" is derived.
enum HomeTripDayLabels {
    static func tripStart(_ trip: Trip, deviceCalendar: Calendar = .current) -> DayDate {
        DayDate.from(trip.startDate, calendar: deviceCalendar)
    }

    static func tripEnd(_ trip: Trip, deviceCalendar: Calendar = .current) -> DayDate {
        DayDate.from(trip.endDate, calendar: deviceCalendar)
    }

    /// "Today," as a `DayDate` label in `liveTimeZone`.
    static func todayLabel(liveTimeZone: TimeZone, now: Date = .now, deviceCalendar: Calendar = .current) -> DayDate {
        var liveCalendar = deviceCalendar
        liveCalendar.timeZone = liveTimeZone
        return DayDate.from(now, calendar: liveCalendar)
    }

    /// Same three-way branch as `TripDateBucketing.bucket`, operating on
    /// already-resolved `DayDate` labels instead of raw `Date`s sharing one
    /// `Calendar` — see this enum's own doc comment for why that matters.
    static func bucket(trip: Trip, liveTimeZone: TimeZone, now: Date = .now, deviceCalendar: Calendar = .current) -> TripBucket {
        let start = tripStart(trip, deviceCalendar: deviceCalendar)
        let end = tripEnd(trip, deviceCalendar: deviceCalendar)
        let today = todayLabel(liveTimeZone: liveTimeZone, now: now, deviceCalendar: deviceCalendar)
        if end < today { return .past }
        if start <= today { return .inProgress }
        return .upcoming
    }
}

/// Which register a trip's row renders as.
enum HomeRegisterKind: Equatable {
    /// Nearest upcoming trip (`ahead.first`, not live) — full card + a
    /// countdown ring + a "FIRST UP" strip.
    case next
    /// The live trip (`ahead.first`, in progress) — "Day N of M" + today's
    /// plan inline.
    case now
    /// Any other "ahead" trip — the plain card, unchanged since before this
    /// phase.
    case plain
    /// A "been" trip — the muted compact row.
    case been
}

enum HomeRegister {
    /// Only `ahead.first` ever earns `.next`/`.now` — "only the nearest
    /// trip earns this" (roadmap P5.2) — every other ahead trip is
    /// `.plain`. `bucket` must be the same value the caller used to build
    /// `aheadFirstId` (both ultimately come from the same per-trip
    /// `TripDateBucketing.liveTimeZone`-aware bucket, see `ordered(_:
    /// bucket:)`'s doc comment) so the two can't disagree about whether
    /// this trip is even in `ahead` at all.
    static func kind(for trip: Trip, aheadFirstId: UUID?, bucket: TripBucket) -> HomeRegisterKind {
        if bucket.isPastTab { return .been }
        guard trip.id == aheadFirstId else { return .plain }
        return bucket == .inProgress ? .now : .next
    }
}

// MARK: - Register "next" — the "FIRST UP" strip

/// P5.2: the "next" register's "FIRST UP" strip content, resolved once from
/// an `ItineraryItem` so `TripCard` only ever renders strings — mirrors
/// `TimelineCardModel`'s "resolve display strings up front" convention
/// (`TimelineModels.swift`).
struct HomeFirstUp: Equatable {
    let systemImage: String
    /// "JL901 · HND → OKA" for a flight with a route on file; the item's
    /// plain title otherwise.
    let text: String
    let weekday: String
    let time: String

    /// The trip's first still-ahead confirmed item — earliest `startsAt` at
    /// or after `now`. Confirmed-only: an unreviewed email-import
    /// suggestion must never surface here, the same rule `TripView`'s own
    /// `@Query` already enforces for the trusted itinerary/bookings tabs.
    /// `nil` once every item is behind `now` (or the trip has none yet) —
    /// the caller omits the strip.
    static func pick(from items: [ItineraryItem], now: Date = .now) -> ItineraryItem? {
        items
            .filter { $0.status == .confirmed && $0.startsAt >= now }
            .min { $0.startsAt < $1.startsAt }
    }

    init(item: ItineraryItem) {
        systemImage = item.category.symbolName
        if item.category == .flight,
            let from = item.details.fromIATA, let to = item.details.toIATA,
            !from.isEmpty, !to.isEmpty {
            text = "\(item.title) \u{00B7} \(from) \u{2192} \(to)"
        } else {
            text = item.title
        }
        // The item's own primary (departure) zone — same zone
        // `TimelineCardModel.timeText` already uses for this item's time.
        let tz = item.primaryTz
        weekday = HomeFirstUp.weekdayText(for: item.startsAt, in: tz)
        time = ItineraryTimeZone.timeString(item.startsAt, in: tz)
    }

    /// "Wed" — kept local rather than added to `ItineraryTimeZone.swift`
    /// (outside this phase's file list): one-line `DateFormatter`, same
    /// recipe as that file's own `timeString`.
    static func weekdayText(for date: Date, in tz: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        formatter.timeZone = tz
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

// MARK: - Register "now" — today's plan + day progress

enum HomeTodayPlan {
    /// Today's plan rows, sourced from the SAME day-bucketing the itinerary
    /// tab renders from (`ItineraryDayBucketing.sections`) — not a
    /// standalone `startLocalDay == today` filter (reviewer MED finding):
    /// that missed an ONGOING multi-night stay whose check-in was an
    /// earlier day, since its own `startsAt` never falls on today even
    /// though the itinerary's today section carries a `.staying` row for
    /// it. Sourcing from the same function means Home's "+K more today"
    /// can never disagree with what tapping into the itinerary and looking
    /// at today's section actually shows. `tripStart` is the trip's own
    /// start `DayDate` (`HomeTripDayLabels.tripStart`) — `sections` numbers/
    /// expands multi-day stays relative to it. Confirmed-only:
    /// `sections` itself already drops `status == .suggested` (EI-2).
    static func items(
        in items: [ItineraryItem], tripStart: DayDate, liveTimeZone: TimeZone, now: Date = .now
    ) -> [ItineraryDayBucketing.Row] {
        let today = HomeTripDayLabels.todayLabel(liveTimeZone: liveTimeZone, now: now)
        let sections = ItineraryDayBucketing.sections(items: items, tripStart: tripStart)
        return sections.first(where: { $0.day == today })?.rows ?? []
    }
}

/// P5.3's "Day N of M" pill + inline "Today · …" mini-list, resolved once
/// per render — same "render strings, not models" convention as
/// `HomeFirstUp` above.
struct HomeTodayPanel: Equatable {
    struct Row: Equatable {
        let time: String
        let title: String
    }

    /// 1-based; day 1 is the trip's own start date.
    let dayNumber: Int
    let totalDays: Int
    /// "Wed 24 Jul", in the trip's live zone.
    let dateText: String
    /// First two of today's rows.
    let rows: [Row]
    /// How many more of today's rows aren't in `rows`.
    let moreCount: Int

    /// `todayRows` is already resolved (`HomeTodayPlan.items(...)`, today's
    /// section only, itinerary-order) — this only formats it plus the
    /// day-progress numbers. `dayNumber` reuses `ItineraryDayBucketing
    /// .dayNumber` (the itinerary tab's own "Day N" math, BUILD_PLAN.md
    /// §4.2) rather than re-deriving day-count math a second way, clamped
    /// into `1...totalDays` so a same-day edit or a trip judged live right
    /// at a boundary can't report Day 0 or an out-of-range N. `today`/
    /// `tripStart` both route through `HomeTripDayLabels` — the one shared
    /// helper `HomeView.bucket(for:)` also uses, so the two can't drift
    /// apart on how "today" is derived (reviewer finding).
    static func make(
        trip: Trip, todayRows: [ItineraryDayBucketing.Row], now: Date = .now, liveTimeZone: TimeZone,
        deviceCalendar: Calendar = .current
    ) -> HomeTodayPanel {
        let today = HomeTripDayLabels.todayLabel(liveTimeZone: liveTimeZone, now: now, deviceCalendar: deviceCalendar)
        let tripStart = HomeTripDayLabels.tripStart(trip, deviceCalendar: deviceCalendar)
        let totalDays = max(trip.durationInDays(calendar: deviceCalendar), 1)
        let rawDayNumber = ItineraryDayBucketing.dayNumber(
            for: today, tripStart: tripStart, calendar: Calendar(identifier: .gregorian)
        )
        let dayNumber = min(max(rawDayNumber, 1), totalDays)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE d MMM"
        dateFormatter.timeZone = liveTimeZone
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let rows = todayRows.prefix(2).map(displayRow)
        return HomeTodayPanel(
            dayNumber: dayNumber, totalDays: totalDays, dateText: dateFormatter.string(from: now),
            rows: Array(rows), moreCount: max(0, todayRows.count - rows.count)
        )
    }

    /// A bucketed row's own (time, title) for the mini-list — `.item` shows
    /// its start time same as before; `.staying`/`.checkOut` have no single
    /// clock time of their own (an all-day backdrop / the checkout instant
    /// respectively aren't "when this row starts" the way a plain item's
    /// `startsAt` is), so those get a wording cue instead, same "Staying"/
    /// "Check out" vocabulary `StayingStripRow`/`CheckOutRow`
    /// (`TimelineRowViews.swift`) already use on the itinerary tab.
    private static func displayRow(_ row: ItineraryDayBucketing.Row) -> Row {
        switch row {
        case .item(let item):
            return Row(time: ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz), title: item.title)
        case .staying(let item, _, _):
            return Row(time: "", title: "Staying \u{00B7} \(item.title)")
        case .checkOut(let item):
            let time = item.endsAt.map { ItineraryTimeZone.timeString($0, in: item.effectiveTz) } ?? ""
            return Row(time: time, title: "Check out \u{00B7} \(item.title)")
        }
    }
}

// MARK: - Register "been" — compact row subtitle

enum HomeBeenSummary {
    /// "Feb · 4 days · 6 items." Reviewer nit: `days` clamped to at least 1
    /// — same defensive floor `HomeTodayPanel.make`'s own `totalDays`
    /// already applies, for the same reason (nothing stops a corrupted
    /// import/edit from producing `startDate > endDate`, which would
    /// otherwise print a nonsensical "−3 days").
    static func subtitleText(trip: Trip, itemCount: Int, calendar: Calendar = .current) -> String {
        let month = trip.startDate.formatted(.dateTime.month(.abbreviated))
        let days = max(trip.durationInDays(calendar: calendar), 1)
        return "\(month) \u{00B7} \(days) day\(days == 1 ? "" : "s") \u{00B7} \(itemCount) item\(itemCount == 1 ? "" : "s")"
    }
}

// MARK: - Register "been" — "Show past trips" setting (UX P6.5)

/// `.claude/company/ux-redesign/DECISIONS.md` 2026-07-15 "Client additions
/// mid-P7": a device-local `@AppStorage` preference (deliberately not
/// synced — every device gets its own choice) that collapses the entire
/// "been" register into one quiet reveal row instead of hiding it with no
/// trace, so turning it off never reads as data loss. Both `SettingsView`
/// (the toggle) and `HomeView` (the row) read the SAME key via this one
/// constant, so the two can't drift apart on a typo'd string literal.
enum HomePastTripsVisibility {
    static let appStorageKey = "showPastTrips"

    /// `false` whenever there's nothing to hide (zero past trips) even if
    /// the setting itself is off — an empty archive has no row to
    /// collapse, same as `HomeView`'s existing "been" section only
    /// rendering at all once `beenTrips` is non-empty.
    static func shouldShowHiddenRow(showPastTrips: Bool, beenCount: Int) -> Bool {
        !showPastTrips && beenCount > 0
    }

    /// "N past trips hidden" — `HomeView`'s reveal row combines this with
    /// "Show" into one VoiceOver stop (count + the action, per the P6.5
    /// brief) the same way `BeenRow`'s own label above combines a trip's
    /// title with its subtitle.
    static func hiddenRowText(beenCount: Int) -> String {
        "\(beenCount) past trip\(beenCount == 1 ? "" : "s") hidden"
    }
}

// MARK: - Greeting loading/settled split (P7b craft audit)

/// `HomeView.greetingBlock`'s loading-vs-settled decision, split out so it's
/// unit-testable without a view hierarchy — same house pattern as
/// `HomeEmptyPlaceholder.resolve`/`HomeRegister.kind` above. Closes a P7
/// award-audit finding: the old inline check (`myDisplayName == nil &&
/// authManager.userId != nil && !syncStatus.hasCompletedInitialHomePull`)
/// treated "offline, first pull never completed" as indistinguishable from
/// "still loading" — but `pullHome()` no-ops while offline
/// (`HomeEmptyPlaceholder`'s own `.offlineFirstLoad` case doc comment), so
/// `hasCompletedInitialHomePull` can never flip true on an offline launch,
/// leaving the redacted "Good morning, Traveler" skeleton up FOREVER
/// whenever there's no cached profile to hydrate from — every `home-*` P7
/// screenshot shows exactly this. `isOffline` now settles the decision the
/// same way `HomeEmptyPlaceholder.resolve` already treats it: a fact to
/// render around (a plain, nameless "Good morning,"), not a reason to keep
/// waiting.
enum HomeGreetingLoading {
    static func isStillLoading(hasDisplayName: Bool, isSignedIn: Bool, hasCompletedInitialHomePull: Bool, isOffline: Bool) -> Bool {
        guard isSignedIn, !hasDisplayName else { return false }
        return !hasCompletedInitialHomePull && !isOffline
    }
}
