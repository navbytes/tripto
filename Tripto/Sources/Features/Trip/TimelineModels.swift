import Foundation

/// Value snapshots for timeline rows (§7.2: "Equatable row views over value
/// snapshots so unrelated pendingRowIds changes don't re-render every
/// card"). `TimelineBuilder` flattens `ItineraryDayBucketing`'s sections
/// into these, resolving every display string up front — row views render
/// snapshots and never touch `ItineraryItem` (so SwiftUI's Equatable
/// short-circuit actually works; `@Model` references would defeat it).
struct TimelineDayModel: Identifiable, Equatable {
    let id: String
    /// "Day 3 · Fri May 16" (or "Before/After the trip · …" outside the
    /// trip's own date range — finding F8).
    let title: String
    let rows: [TimelineRowModel]
    /// True when this section's day is the viewer's device-local "today"
    /// (finding F1) — the view uses this to render a small "Today" marker
    /// and to drive the one-shot auto-scroll.
    let isToday: Bool

    /// Finding F2: a day with no rows at all (a gap day the bucketing layer
    /// filled in) — the view renders this as a quiet "Free day" row instead
    /// of an empty section.
    var isFreeDay: Bool { rows.isEmpty }
}

enum TimelineRowModel: Identifiable, Equatable {
    case card(TimelineCardModel)
    case staying(StayingStripModel)
    case checkOut(CheckOutRowModel)
    case tzShift(TZShiftModel)

    var id: String {
        switch self {
        case .card(let model): "card-\(model.id.uuidString)"
        case .staying(let model): model.id
        case .checkOut(let model): model.id
        case .tzShift(let model): model.id
        }
    }
}

struct TimelineCardModel: Identifiable, Equatable {
    let id: UUID
    let category: ItemCategory
    /// "08:20" in the item's own zone.
    let timeText: String
    /// "EDT" — present when this item's zone differs from the previous
    /// item's effective zone, and always for flights (a flight's departure
    /// time is never rendered unlabeled — ACCEPTANCE A1.1).
    let zoneLabel: String?
    let title: String
    let subtitle: String
    let hasTicket: Bool
    let isPending: Bool
    /// "edited by Priya · 2 hours ago" — nil unless updated_by is someone
    /// else and the edit is < 48h old.
    let editedBy: String?
    /// "Just mine" assignee cluster (BUILD_PLAN.md §5.4, §6.3 "avatar
    /// stacks for members/assignees") — empty when the item has no
    /// `item_assignees` rows (unassigned = for everyone, per
    /// `PersonFilter`'s doc comment).
    let assignees: [AvatarStack.Person]
    /// Kid-aware tags (this milestone's brief), raw `details.tags` strings —
    /// rendered via `ItemTag`'s label/icon where recognized, plain text
    /// otherwise (`TimelineRowViews.swift`'s tag chip).
    let tags: [String]
}

struct StayingStripModel: Identifiable, Equatable {
    let id: String
    let itemId: UUID
    /// "Staying at Memmo Alfama Hotel — night 2 of 3"
    let text: String
}

struct CheckOutRowModel: Identifiable, Equatable {
    let id: String
    let itemId: UUID
    let timeText: String
    let zoneLabel: String?
    let title: String
    let isPending: Bool
}

struct TZShiftModel: Identifiable, Equatable {
    let id: String
    let text: String
}

enum TimelineBuilder {
    static let editedByWindow: TimeInterval = 48 * 3600

    /// Flattens bucketed sections into render-ready day models. Chip and
    /// zone-label decisions track the previous *instant-bearing* row
    /// (cards and check-out rows; staying strips are all-day backdrops and
    /// never participate in zone comparisons).
    static func build(
        sections: [ItineraryDayBucketing.Section],
        pendingRowIds: Set<UUID>,
        myUserId: UUID?,
        namesById: [UUID: String],
        assigneesByItem: [UUID: [AvatarStack.Person]] = [:],
        now: Date = .now,
        /// Finding F1: the viewer's device-local "today", passed in (rather
        /// than computed here) so the builder stays pure/testable — the
        /// caller derives it via `DayDate.from(.now, calendar: .current)`.
        today: DayDate? = nil,
        /// Finding F8: total day count of the trip itself (`endDate` -
        /// `startDate` inclusive) — `nil` keeps the old unconditional
        /// "Day N" title for existing call sites.
        tripDayCount: Int? = nil
    ) -> [TimelineDayModel] {
        var previous: ItineraryItem?

        return sections.map { section in
            var rows: [TimelineRowModel] = []

            for row in section.rows {
                switch row {
                case .staying(let item, let night, let totalNights):
                    rows.append(.staying(StayingStripModel(
                        id: row.id,
                        itemId: item.id,
                        text: "Staying at \(item.title) — night \(night) of \(totalNights)"
                    )))

                case .item(let item):
                    if let previous, let chip = TZShiftChip.zoneChangeText(previous: previous, next: item) {
                        rows.append(.tzShift(TZShiftModel(id: "shift-to-\(item.id.uuidString)", text: chip)))
                    }
                    rows.append(.card(cardModel(
                        for: item,
                        previous: previous,
                        pendingRowIds: pendingRowIds,
                        myUserId: myUserId,
                        namesById: namesById,
                        assignees: assigneesByItem[item.id] ?? [],
                        now: now
                    )))
                    // The landing chip rides directly under its flight —
                    // even when the next item is already in the arrival
                    // zone (ACCEPTANCE A1.3), and even when nothing follows.
                    if let landing = TZShiftChip.landingText(for: item) {
                        rows.append(.tzShift(TZShiftModel(id: "landing-\(item.id.uuidString)", text: landing)))
                    }
                    previous = item

                case .checkOut(let item):
                    let zoneChanged = ItineraryTimeZone.zoneChanged(from: previous, to: item)
                    let endsAt = item.endsAt ?? item.startsAt
                    rows.append(.checkOut(CheckOutRowModel(
                        id: row.id,
                        itemId: item.id,
                        timeText: ItineraryTimeZone.timeString(endsAt, in: item.primaryTz),
                        zoneLabel: zoneChanged
                            ? ItineraryTimeZone.zoneLabel(for: item.primaryTz, at: endsAt) : nil,
                        title: "Check-out · \(item.title)",
                        isPending: pendingRowIds.contains(item.id)
                    )))
                    previous = item
                }
            }

            return TimelineDayModel(
                id: section.day.stringValue,
                title: dayTitle(for: section, tripDayCount: tripDayCount),
                rows: rows,
                isToday: today != nil && section.day == today
            )
        }
    }

    /// Finding F8: "Day N" only reads sensibly for days inside the trip's
    /// own range — a stray item the day before check-in (or after
    /// check-out) previously rendered as "Day 0" or a negative day number,
    /// which reads as a bug. Outside the range this labels the day as what
    /// it is instead of pretending it's part of the numbered itinerary.
    private static func dayTitle(for section: ItineraryDayBucketing.Section, tripDayCount: Int?) -> String {
        let dateText = dayTitleText(section.day)
        if section.dayNumber < 1 {
            return "Before the trip · \(dateText)"
        }
        if let tripDayCount, section.dayNumber > tripDayCount {
            return "After the trip · \(dateText)"
        }
        return "Day \(section.dayNumber) · \(dateText)"
    }

    private static func cardModel(
        for item: ItineraryItem,
        previous: ItineraryItem?,
        pendingRowIds: Set<UUID>,
        myUserId: UUID?,
        namesById: [UUID: String],
        assignees: [AvatarStack.Person],
        now: Date
    ) -> TimelineCardModel {
        let zoneChanged = ItineraryTimeZone.zoneChanged(from: previous, to: item)
        // Flights always label their departure time (A1.1: never a bare
        // "08:20" for the zone-sensitive category); everything else labels
        // only on a crossing to keep the gutter quiet.
        let showZone = zoneChanged || item.category == .flight
        return TimelineCardModel(
            id: item.id,
            category: item.category,
            timeText: ItineraryTimeZone.timeString(item.startsAt, in: item.primaryTz),
            zoneLabel: showZone ? ItineraryTimeZone.zoneLabel(for: item.primaryTz, at: item.startsAt) : nil,
            title: item.title,
            subtitle: subtitle(for: item),
            hasTicket: !(item.confirmation ?? "").isEmpty,
            isPending: pendingRowIds.contains(item.id),
            editedBy: editedByText(for: item, myUserId: myUserId, namesById: namesById, now: now),
            assignees: assignees,
            tags: item.details.tags
        )
    }

    /// Per-category card subtitle (this milestone's brief §"Itinerary tab").
    static func subtitle(for item: ItineraryItem) -> String {
        let details = item.details
        switch item.category {
        case .flight:
            var parts: [String] = []
            if let from = details.fromIATA, let to = details.toIATA, !from.isEmpty, !to.isEmpty {
                parts.append("\(from) → \(to)")
            }
            if let seat = details.seat, !seat.isEmpty {
                parts.append("Seat \(seat)")
            }
            if parts.isEmpty, !item.locationName.isEmpty {
                parts.append(item.locationName)
            }
            return parts.isEmpty ? "Flight" : parts.joined(separator: " · ")
        case .hotel:
            let nights = item.stayNightCount
            return nights > 0 ? "Check-in · \(nights) night\(nights == 1 ? "" : "s")" : "Check-in"
        case .activity:
            if let address = details.address, !address.isEmpty { return address }
            if !item.locationName.isEmpty { return item.locationName }
            if let ticket = details.ticketRef, !ticket.isEmpty { return "Ticket \(ticket)" }
            return "Activity"
        case .food:
            var parts: [String] = []
            if let partySize = details.partySize {
                parts.append("Reservation for \(partySize)")
            }
            if let address = details.address, !address.isEmpty {
                parts.append(address)
            } else if !item.locationName.isEmpty {
                parts.append(item.locationName)
            }
            return parts.isEmpty ? "Food" : parts.joined(separator: " · ")
        case .transport:
            var parts: [String] = []
            if let provider = details.provider, !provider.isEmpty { parts.append(provider) }
            if let dropoff = details.dropoffLocation, !dropoff.isEmpty {
                parts.append("to \(dropoff)")
            } else if !item.locationName.isEmpty {
                parts.append(item.locationName)
            }
            return parts.isEmpty ? "Transport" : parts.joined(separator: " · ")
        }
    }

    static func editedByText(
        for item: ItineraryItem,
        myUserId: UUID?,
        namesById: [UUID: String],
        now: Date
    ) -> String? {
        guard
            let updatedBy = item.updatedBy,
            updatedBy != myUserId,
            now.timeIntervalSince(item.updatedAt) < editedByWindow,
            now.timeIntervalSince(item.updatedAt) >= 0
        else { return nil }
        let name = namesById[updatedBy] ?? "someone"
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let relative = formatter.localizedString(for: item.updatedAt, relativeTo: now)
        return "edited by \(name) · \(relative)"
    }

    /// "Fri May 16" — the day header's date half, formatted against UTC
    /// midnight of the `DayDate` so the weekday never shifts with the
    /// viewer's zone (the day sections themselves are already zone-resolved).
    /// Internal (not `private`): `BookingsTabView` reuses this for its own
    /// per-row date text rather than re-deriving the same format.
    static func dayTitleText(_ day: DayDate) -> String {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE MMM d"
        formatter.timeZone = utc.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: day.asDate(calendar: utc))
    }
}
