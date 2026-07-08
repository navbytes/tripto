import SwiftUI

/// Bridges the one dismiss signal SwiftUI's `.sheet` doesn't expose: a
/// swipe-to-dismiss *attempt* against `.interactiveDismissDisabled` (UX
/// audit finding 5). Without this, a dirty form's swipe-down just
/// rubber-bands with no explanation — this makes the attempt surface the
/// same "Discard changes?" dialog `Cancel` already shows.
///
/// `UIAdaptivePresentationControllerDelegate` is UIKit-only, so this is a
/// small `UIViewControllerRepresentable` bridge — the standard workaround
/// for SwiftUI's lack of a native `onDismissAttempt`. Placed in
/// Design/Components (not Home) because `AddItemSheet` has the identical
/// gap; wiring it there is out of scope for this pass.
///
/// Installing `coordinator` as the presentation controller's delegate
/// *replaces* whatever delegate SwiftUI itself installed there (the object
/// that drives `didDismiss`/`willDismiss` and keeps the `.sheet`'s
/// `isPresented` binding in sync after a clean, undisabled dismiss). So the
/// coordinator wraps-and-forwards: it captures that prior delegate as
/// `forwardTo`, answers only `presentationControllerDidAttemptToDismiss`
/// itself, and relays every other selector (via `responds(to:)` /
/// `forwardingTarget(for:)`) back to SwiftUI's own delegate. It does *not*
/// implement `presentationControllerShouldDismiss` — leaving that
/// unanswered lets the forwarded-to delegate (or, if there is none, the
/// system default) keep it as the sole gate, so `.interactiveDismissDisabled`
/// on the SwiftUI side remains authoritative.
struct SheetDismissAttemptObserver: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> ObserverViewController {
        let controller = ObserverViewController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ObserverViewController, context: Context) {
        uiViewController.attachDelegate()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onAttempt: onAttempt)
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        let onAttempt: () -> Void
        /// The delegate SwiftUI installed before this coordinator took over —
        /// forwarded every selector this coordinator doesn't itself
        /// implement, so `didDismiss` etc. still reach SwiftUI.
        weak var forwardTo: UIAdaptivePresentationControllerDelegate?

        init(onAttempt: @escaping () -> Void) { self.onAttempt = onAttempt }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt()
            forwardTo?.presentationControllerDidAttemptToDismiss?(presentationController)
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (forwardTo?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if super.responds(to: aSelector) { return nil }
            return forwardTo
        }
    }

    final class ObserverViewController: UIViewController {
        var coordinator: Coordinator?

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            attachDelegate()
        }

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attachDelegate()
        }

        /// Walks up to the nearest *presented* ancestor — this representable
        /// is hosted deep inside the sheet's own content hierarchy (behind
        /// the `NavigationStack`), not on the presented controller itself.
        /// Wraps-and-forwards: if a different delegate is already installed
        /// (SwiftUI's own), it's preserved on `coordinator.forwardTo` before
        /// the coordinator takes its place, so re-attaching (e.g. from
        /// `updateUIViewController` on a later update pass, if SwiftUI
        /// reinstalls its delegate) never captures the coordinator itself as
        /// its own forwarding target.
        func attachDelegate() {
            guard let coordinator else { return }
            var candidate: UIViewController? = self
            while let current = candidate {
                if current.presentingViewController != nil {
                    if let existing = current.presentationController?.delegate, !(existing === coordinator) {
                        coordinator.forwardTo = existing
                    }
                    current.presentationController?.delegate = coordinator
                    return
                }
                candidate = current.parent
            }
        }
    }
}
