import Foundation

/// Plain-language "what this role can do," in one place so the role picker, the
/// invite-link buttons, and a member's own-role card never drift. The persona
/// dry-run found a Companion had no way to learn what "Companion" even meant —
/// the copy previously lived only inside the organizer-only role picker.
extension TripRole {
    /// Full sentence, for the role picker and a member's own-role card.
    var capabilityDescription: String {
        switch self {
        case .organizer: return "Full control \u{2014} edit everything, manage people."
        case .companion: return "Add plans and edit the items you add."
        case .viewer: return "See the itinerary \u{2014} viewing only, no editing."
        }
    }

    /// Short grant shown under an invite-link button, so an organizer knows
    /// what a link grants before sending it.
    var inviteGrant: String {
        switch self {
        case .organizer: return "Full control"
        case .companion: return "Can add & edit their own plans"
        case .viewer: return "Can view, not edit"
        }
    }
}
