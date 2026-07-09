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
    /// copied"`).
    @discardableResult
    static func copy(_ value: String, label: String) -> String {
        UIPasteboard.general.string = value
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        return "\(label) copied"
    }
}
