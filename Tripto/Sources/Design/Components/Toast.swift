import SwiftUI

/// Lightweight bottom toast (BUILD_PLAN.md §6.6: "button 'Add flight' →
/// toast 'Flight added'"). Screens own a `@State private var toast:
/// String?` and attach `.toastOverlay($toast)`; setting the binding shows
/// the message and auto-clears it after a reading-time-scaled delay (see
/// `displayDuration(for:)`). Deliberately not a global center — every M2
/// surface that toasts (timeline, add sheet host, booking detail) is its
/// own screen with its own overlay.
struct ToastOverlay: ViewModifier {
    @Binding var message: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(Typo.body(weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
                    .background(Palette.indigo, in: Capsule())
                    .shadow(color: Palette.shadow.opacity(0.25), radius: 12, y: 6)
                    .padding(.bottom, Spacing.xxl)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        // `.updatesFrequently` alone announces nothing —
                        // VoiceOver needs an explicit announcement to speak
                        // a toast that appears and vanishes on its own
                        // (finding 6 rider, benefits every toast surface).
                        AccessibilityNotification.Announcement(message).post()
                        try? await Task.sleep(for: .seconds(Self.displayDuration(for: message)))
                        guard !Task.isCancelled else { return }
                        withAnimation(.easeOut(duration: reduceMotion ? 0 : 0.2)) {
                            self.message = nil
                        }
                    }
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.3), value: message)
    }

    /// UX audit finding 3: a flat two-second timer clips longer toasts (the
    /// 33-character refresh-failure message) before a reader gets through
    /// them, while padding out a short one ("Flight added"). Scales with
    /// message length instead — 2.0s floor for short toasts, ~4.0s cap so a
    /// pathological message can't linger indefinitely. Pure/static so it's
    /// directly unit-testable without standing up a view hierarchy.
    static func displayDuration(for message: String) -> TimeInterval {
        min(max(2.0, 1.2 + 0.055 * Double(message.count)), 4.0)
    }
}

extension View {
    func toastOverlay(_ message: Binding<String?>) -> some View {
        modifier(ToastOverlay(message: message))
    }
}

private struct ToastPreviewHost: View {
    @State private var toast: String? = "Flight added"

    var body: some View {
        VStack {
            Button("Show toast") { toast = "Flight added" }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.paper)
        .toastOverlay($toast)
    }
}

#Preview {
    ToastPreviewHost()
}
