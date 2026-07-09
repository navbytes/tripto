import Foundation

/// Plain-language "what this role can do," in one place so the role picker, the
/// invite-link buttons, and a member's own-role card never drift. The persona
/// dry-run found a Companion had no way to learn what "Companion" even meant —
/// the copy previously lived only inside the organizer-only role picker.
///
/// Two distinct audiences read this copy, so there are two grant strings:
/// `inviteGrant` is organizer-facing (third person, "what this link grants,
/// before you send it"), while `inviteeGrant` is invitee-facing (second
/// person, shown to the person accepting an invite on `WelcomeView`). Don't
/// collapse them — the usability dry-run flagged third-person copy ("their
/// own plans") reading oddly when addressed to the person it describes.
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

    /// Short grant shown to the person accepting an invite (second person,
    /// addressed to them directly) — `WelcomeView`'s pre-sign-in invite card.
    var inviteeGrant: String {
        switch self {
        case .organizer: return "Full control"
        case .companion: return "Can add & edit your own plans"
        case .viewer: return "Can view, not edit"
        }
    }
}
