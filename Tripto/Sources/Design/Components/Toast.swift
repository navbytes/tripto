import SwiftUI

/// Lightweight bottom toast (BUILD_PLAN.md §6.6: "button 'Add flight' →
/// toast 'Flight added'"). Screens own a `@State private var toast:
/// String?` and attach `.toastOverlay($toast)`; setting the binding shows
/// the message and auto-clears it after two seconds. Deliberately not a
/// global center — every M2 surface that toasts (timeline, add sheet host,
/// booking detail) is its own screen with its own overlay.
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
                    .shadow(color: Palette.ink.opacity(0.25), radius: 12, y: 6)
                    .padding(.bottom, Spacing.xxl)
                    .transition(reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity))
                    .task(id: message) {
                        try? await Task.sleep(nanoseconds: 2_000_000_000)
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
