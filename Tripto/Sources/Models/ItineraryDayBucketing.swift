import Foundation

/// Day-grouping and multi-day-stay expansion for the itinerary timeline
/// (BUILD_PLAN.md §4.2; ACCEPTANCE.md "(c)"). Pure, deliberately
/// calendar-parameterized (the `TripDateBucketing`/`DayDate` pattern this
/// mirrors) — no SwiftData, no `Calendar.current` baked in, so the exact
/// UTC-crossing/DST boundary cases are directly unit testable regardless of
/// the machine running them.
enum ItineraryDayBucketing {
    /// One row in a day's section. Multi-day items (chiefly hotel stays)
    /// expand into up to three row kinds spread across N+1 calendar days
    /// (ACCEPTANCE.md "(c)"); everything else is a single `.item` row.
    enum Row: Identifiable, Equatable {
        case item(ItineraryItem)
        /// A quiet mid-stay marker. `night` is the night *beginning* on that
        /// day's evening: check-in evening is night 1 (carried by the
        /// check-in card itself), so the first intermediate day reads
        /// "night 2 of {totalNights}".
        case staying(item: ItineraryItem, night: Int, totalNights: Int)
        case checkOut(item: ItineraryItem)

        var id: String {
            switch self {
            case .item(let item): "item-\(item.id.uuidString)"
            case .staying(let item, let night, _): "staying-\(item.id.uuidString)-\(night)"
            case .checkOut(let item): "checkout-\(item.id.uuidString)"
            }
        }

        var item: ItineraryItem {
            switch self {
            case .item(let item), .staying(let item, _, _), .checkOut(let item): item
            }
        }

        static func == (lhs: Row, rhs: Row) -> Bool { lhs.id == rhs.id }
    }

    struct Section: Identifiable {
        let day: DayDate
        let dayNumber: Int
        let rows: [Row]
        var id: DayDate { day }
    }

    /// Builds day sections for every day touched by at least one row —
    /// `status == 'suggested'` items are dropped up front (v1 only ever
    /// renders `'confirmed'`, BUILD_PLAN.md §5.6). Sections are sorted by
    /// day; rows within a day are sorted by instant, with `.staying` rows
    /// (no meaningful instant *on* that day — the stay spans the whole day)
    /// pinned first so they read as an all-day backdrop rather than
    /// competing with the day's scheduled items.
    static func sections(
        items: [ItineraryItem],
        tripStart: DayDate,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [Section] {
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!

        var rowsByDay: [DayDate: [Row]] = [:]

        for item in items where item.status == .confirmed {
            let startDay = item.startLocalDay

            guard let endDay = item.endLocalDay, endDay > startDay else {
                rowsByDay[startDay, default: []].append(.item(item))
                continue
            }

            // Multi-day item (ACCEPTANCE.md "(c)") — full card on the
            // check-in day, a staying strip on every day strictly between,
            // a check-out chip on the final day.
            rowsByDay[startDay, default: []].append(.item(item))

            let totalNights = dayCount(from: startDay, to: endDay, calendar: utcCalendar)
            var cursor = startDay
            while cursor < endDay {
                guard let nextDate = utcCalendar.date(byAdding: .day, value: 1, to: cursor.asDate(calendar: utcCalendar))
                else { break }
                cursor = DayDate.from(nextDate, calendar: utcCalendar)
                if cursor == endDay {
                    rowsByDay[cursor, default: []].append(.checkOut(item: item))
                } else {
                    let night = dayCount(from: startDay, to: cursor, calendar: utcCalendar) + 1
                    rowsByDay[cursor, default: []].append(.staying(item: item, night: night, totalNights: totalNights))
                }
            }
        }

        return rowsByDay.keys.sorted().map { day in
            let rows = rowsByDay[day, default: []].sorted { sortKey($0) < sortKey($1) }
            return Section(day: day, dayNumber: dayNumber(for: day, tripStart: tripStart, calendar: utcCalendar), rows: rows)
        }
    }

    /// "Day N" numbering is 1-based from the trip's own start date, not from
    /// whatever day happens to have the earliest item.
    static func dayNumber(for day: DayDate, tripStart: DayDate, calendar: Calendar) -> Int {
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        return dayCount(from: tripStart, to: day, calendar: utcCalendar) + 1
    }

    /// Inclusive-of-neither-endpoint day count, i.e. plain calendar-day
    /// subtraction — used both for "N nights" and for "Day N" numbering.
    static func dayCount(from: DayDate, to: DayDate, calendar: Calendar) -> Int {
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(identifier: "UTC")!
        return utcCalendar.dateComponents(
            [.day], from: from.asDate(calendar: utcCalendar), to: to.asDate(calendar: utcCalendar)
        ).day ?? 0
    }

    private static func sortKey(_ row: Row) -> (Int, Date) {
        switch row {
        case .staying: return (0, .distantPast)
        case .item(let item): return (1, item.startsAt)
        case .checkOut(let item): return (1, item.endsAt ?? item.startsAt)
        }
    }
}

extension ItineraryItem {
    /// Night count for a stay (`endLocalDay - startLocalDay`), used by the
    /// timeline card's "Check-in · N nights" subtitle. `0` when there's no
    /// `ends_at` or it doesn't cross a calendar day.
    var stayNightCount: Int {
        guard let endLocalDay, endLocalDay > startLocalDay else { return 0 }
        return ItineraryDayBucketing.dayCount(from: startLocalDay, to: endLocalDay, calendar: Calendar(identifier: .gregorian))
    }
}
