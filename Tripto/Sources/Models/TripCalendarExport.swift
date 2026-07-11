import Foundation

/// Pure decision logic behind E1 "Add Trip to Calendar" (docs/BACKLOG.md
/// §E1) — the whole-trip sibling of `CalendarEventDraft.swift`'s per-item
/// export. Deliberately Foundation-only, no `EventKit`, so eligibility,
/// idempotency, and the result toast's count math are all testable with no
/// calendar permission and no `EKEventStore` involved. `TripView.swift` is
/// the only place that touches EventKit for the batch export — mirroring
/// how `BookingDetailView.swift` is the sole EventKit call site for the
/// per-item one (see that type's own doc comment).
enum TripCalendarExport {
    /// E1's brief, verbatim: the trip's "CONFIRMED itinerary items (status
    /// == .confirmed only — never suggested) that have a start time."
    /// `startsAt` is non-optional on the real `ItineraryItem` model, so a
    /// missing start time can't happen with today's data — kept as `Date?`
    /// here (rather than folding this into a bare status check) so the full
    /// predicate is independently testable instead of resting on the model
    /// never changing.
    static func isEligible(status: ItemStatus, startsAt: Date?) -> Bool {
        status == .confirmed && startsAt != nil
    }

    /// `TripView`'s own `items` `@Query` already filters to `status ==
    /// confirmed` (EI-2's suggested/confirmed split), so this re-filter is
    /// normally a no-op there — kept anyway so the export is correct
    /// standing alone, not just by inheriting an upstream query's accident.
    static func eligibleItems(_ items: [ItineraryItem]) -> [ItineraryItem] {
        items.filter { isEligible(status: $0.status, startsAt: $0.startsAt) }
    }

    /// E1's brief §3's idempotency tag, stamped onto each created
    /// `EKEvent.url`. `DeepLink.swift` has no item-level link today (only
    /// `tripto://trip/<uuid>`, PLAN-signature-layer.md §D6/§D7's widget/
    /// Spotlight open link) — this is a deliberately narrower shape used
    /// purely as an idempotency key on the calendar event, not parsed by
    /// `.onOpenURL` or built by `DeepLink` itself.
    static func exportTagURL(itemId: UUID) -> URL {
        URL(string: "tripto://item/\(itemId.uuidString)")!
    }

    /// E1's brief §3: "search the calendar in that item's date window for
    /// an event with the same url and skip if present." `existingEventURLs`
    /// is whatever the `EKEventStore`-touching caller already fetched for
    /// that window (a `Set<URL>`, not `[EKEvent]`, so this stays
    /// Foundation-only and hermetically testable).
    static func shouldSkip(itemId: UUID, existingEventURLs: Set<URL>) -> Bool {
        existingEventURLs.contains(exportTagURL(itemId: itemId))
    }

    /// E1's brief §4's result toast — two shapes, verbatim, pluralized the
    /// same way `TripView`'s own "N item(s) added to review" toast already
    /// does.
    struct Summary: Equatable {
        var added: Int
        var skipped: Int

        var message: String {
            skipped == 0
                ? "Added \(added) event\(added == 1 ? "" : "s")"
                : "Added \(added), skipped \(skipped) already there"
        }
    }
}
