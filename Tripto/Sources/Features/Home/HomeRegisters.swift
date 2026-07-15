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
    /// case, matching the roadmap's own "Sort rule."
    static func ahead(_ trips: [Trip], bucket: (Trip) -> TripBucket) -> [Trip] {
        trips.filter { !bucket($0).isPastTab }.sorted { $0.startDate < $1.startDate }
    }

    /// "Been" — already ended — most-recent-first, by `endDate` (not
    /// `startDate`: a trip that started later can still have ended first,
    /// e.g. a quick weekend booked after a longer trip already in progress).
    static func been(_ trips: [Trip], bucket: (Trip) -> TripBucket) -> [Trip] {
        trips.filter { bucket($0).isPastTab }.sorted { $0.endDate > $1.endDate }
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
    /// Today's confirmed items, earliest first — the "now" register's
    /// inline mini-list. "Today" is judged in `liveTimeZone`
    /// (`TripDateBucketing.liveTimeZone` — the trip's own effective zone,
    /// P2.4); each item still buckets into *its own* local day via
    /// `startLocalDay` (its own primary tz), exactly like
    /// `ItineraryDayBucketing` already does for the itinerary tab — this
    /// only narrows that same rule to today.
    static func items(in items: [ItineraryItem], liveTimeZone: TimeZone, now: Date = .now) -> [ItineraryItem] {
        let today = ItineraryTimeZone.localDay(of: now, in: liveTimeZone)
        return items
            .filter { $0.status == .confirmed && $0.startLocalDay == today }
            .sorted { $0.startsAt < $1.startsAt }
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
    /// First two of today's items.
    let rows: [Row]
    /// How many more of today's items aren't in `rows`.
    let moreCount: Int

    /// `todayItems` is already resolved (`HomeTodayPlan.items(...)`, sorted,
    /// today-only) — this only formats it plus the day-progress numbers.
    /// `dayNumber` reuses `ItineraryDayBucketing.dayNumber` (the itinerary
    /// tab's own "Day N" math, BUILD_PLAN.md §4.2) rather than re-deriving
    /// day-count math a second way, clamped into `1...totalDays` so a
    /// same-day edit or a trip judged live right at a boundary can't report
    /// Day 0 or an out-of-range N.
    static func make(
        trip: Trip, todayItems: [ItineraryItem], now: Date = .now, liveTimeZone: TimeZone,
        deviceCalendar: Calendar = .current
    ) -> HomeTodayPanel {
        var tripTzCalendar = deviceCalendar
        tripTzCalendar.timeZone = liveTimeZone
        let today = DayDate.from(now, calendar: tripTzCalendar)
        let tripStart = DayDate.from(trip.startDate, calendar: deviceCalendar)
        let totalDays = max(trip.durationInDays(calendar: deviceCalendar), 1)
        let rawDayNumber = ItineraryDayBucketing.dayNumber(
            for: today, tripStart: tripStart, calendar: Calendar(identifier: .gregorian)
        )
        let dayNumber = min(max(rawDayNumber, 1), totalDays)

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "EEE d MMM"
        dateFormatter.timeZone = liveTimeZone
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")

        let rows = todayItems.prefix(2).map {
            Row(time: ItineraryTimeZone.timeString($0.startsAt, in: $0.primaryTz), title: $0.title)
        }
        return HomeTodayPanel(
            dayNumber: dayNumber, totalDays: totalDays, dateText: dateFormatter.string(from: now),
            rows: Array(rows), moreCount: max(0, todayItems.count - rows.count)
        )
    }
}

// MARK: - Register "been" — compact row subtitle

enum HomeBeenSummary {
    /// "Feb · 4 days · 6 items."
    static func subtitleText(trip: Trip, itemCount: Int, calendar: Calendar = .current) -> String {
        let month = trip.startDate.formatted(.dateTime.month(.abbreviated))
        let days = trip.durationInDays(calendar: calendar)
        return "\(month) \u{00B7} \(days) day\(days == 1 ? "" : "s") \u{00B7} \(itemCount) item\(itemCount == 1 ? "" : "s")"
    }
}
