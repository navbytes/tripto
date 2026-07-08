import SwiftUI
import UIKit

/// Presents the OS share sheet imperatively. Unlike SwiftUI's `ShareLink`
/// (a tap-triggered control with no programmatic-presentation API —
/// `BookingDetailView`'s "Share with group" uses it directly, since that
/// flow has nothing to do first), `ShareTripView`'s invite buttons must
/// *create* the invite row and *then* share its link in one continuous
/// action (M3 brief: "create an invite row of that role, then present the
/// OS share sheet") — this wraps `UIActivityViewController` so a view can
/// drive that presentation from a plain `@State` value instead of a tap.
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct ActivityShareSheetModifier: ViewModifier {
    @Binding var items: [Any]?

    func body(content: Content) -> some View {
        content.sheet(isPresented: Binding(
            get: { items != nil },
            set: { isPresented in if !isPresented { items = nil } }
        )) {
            if let items {
                ActivityShareSheet(items: items)
            }
        }
    }
}

extension View {
    /// Set `items` to a non-nil array to present the OS share sheet with
    /// those activity items; the sheet (or any other code) setting it back
    /// to `nil` dismisses it.
    func activityShareSheet(items: Binding<[Any]?>) -> some View {
        modifier(ActivityShareSheetModifier(items: items))
    }
}
