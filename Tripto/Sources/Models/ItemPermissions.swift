import Foundation

/// Client-side convenience mirror of ACCEPTANCE.md "(b)"'s roles matrix for
/// itinerary items — organizer edits/deletes anything, a companion only
/// their own, a viewer never. **Never** the real security boundary
/// (CLAUDE.md: RLS enforces this server-side; a client bug here can at
/// worst show a button a policy will still reject). Centralized so
/// `AddItemSheet`/`BookingDetailView`/`ItineraryTabView` don't each
/// re-derive "organizer, or companion editing their own item" — the one
/// helper M3/M4's roles work should reuse too.
enum ItemPermissions {
    /// Add itinerary item (ACCEPTANCE.md "(b)": organizer or companion, not viewer).
    static func canAdd(role: TripRole?) -> Bool {
        role == .organizer || role == .companion
    }

    /// Propose a plan without edit rights (BRIEF.md "suggest tray," BUILD_PLAN
    /// §5.6, repurposed for viewers not companions per the engagement's
    /// logged decision) — the mirror image of `canAdd`: viewer only.
    /// Backend RLS grants a matching viewer-only INSERT (status='suggested',
    /// created_by=self); this just gates the client affordance
    /// (`TripView`'s FAB, `AddItemSheet`'s `isSuggesting` mode).
    static func canSuggest(role: TripRole?) -> Bool {
        role == .viewer
    }

    /// Confirm or dismiss a `status == .suggested` item in the review inbox
    /// — organizer or companion, the same shape `canAdd` already grants
    /// (whoever can add an item directly is trusted to review one someone
    /// else proposed). A viewer's own suggestion stays visible to them
    /// (RLS SELECT is unrestricted) but never actionable — `AddItemSheet`
    /// renders a read-only "Waiting for review" state instead, since RLS
    /// grants a viewer no UPDATE/DELETE at all.
    static func canReviewSuggestion(role: TripRole?) -> Bool {
        canAdd(role: role)
    }

    /// Edit/delete a specific item: organizer may touch any item; a
    /// companion only one they created themselves; a viewer never.
    ///
    /// `item.createdBy == nil` means the original creator's account was
    /// deleted (F3 migration: `ON DELETE SET NULL`) — that's never "my own
    /// item," so the companion own-path is explicitly denied rather than
    /// left to an implicit `nil`-vs-`nil` optional comparison.
    static func canEdit(item: ItineraryItem, role: TripRole?, userId: UUID?) -> Bool {
        switch role {
        case .organizer: return true
        case .companion:
            guard let userId, let createdBy = item.createdBy else { return false }
            return createdBy == userId
        case .viewer, .none: return false
        }
    }

    /// Same rule as edit (ACCEPTANCE.md "(b)" gives delete the identical shape).
    static func canDelete(item: ItineraryItem, role: TripRole?, userId: UUID?) -> Bool {
        canEdit(item: item, role: role, userId: userId)
    }

    /// The booking detail's free-text notes block (this milestone's brief:
    /// "editable (organizer or item creator)") — same rule again.
    static func canEditNotes(item: ItineraryItem, role: TripRole?, userId: UUID?) -> Bool {
        canEdit(item: item, role: role, userId: userId)
    }
}
