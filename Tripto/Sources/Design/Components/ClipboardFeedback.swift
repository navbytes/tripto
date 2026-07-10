import UIKit

/// UX audit finding 6: the one shared tap-to-copy pattern — success haptic +
/// an object-specific toast ("Code copied" / "Link copied", not a bare
/// generic "Copied") — so every copy affordance in the app behaves and reads
/// identically. `BookingDetailView` (confirmation/ticket codes) and
/// `ShareTripView` (invite links) both route through this instead of each
/// hand-rolling their own `UIPasteboard`/haptic/toast triple.
enum ClipboardFeedback {
    /// Copies `value` to the pasteboard, plays the standard success haptic,
    /// and returns the toast message the caller should show (`"\(label)
    /// copied"`). Pass `haptic: false` when the call site choreographs its
    /// own feedback beats (PLAN-signature-layer §D3 boarding-pass copy) —
    /// existing callers keep the default and are unchanged.
    @discardableResult
    static func copy(_ value: String, label: String, haptic: Bool = true) -> String {
        UIPasteboard.general.string = value
        if haptic {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        return "\(label) copied"
    }
}
