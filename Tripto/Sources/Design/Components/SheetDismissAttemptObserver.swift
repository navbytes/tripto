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
struct SheetDismissAttemptObserver: UIViewControllerRepresentable {
    let onAttempt: () -> Void

    func makeUIViewController(context: Context) -> ObserverViewController {
        let controller = ObserverViewController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: ObserverViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onAttempt: onAttempt)
    }

    final class Coordinator: NSObject, UIAdaptivePresentationControllerDelegate {
        let onAttempt: () -> Void
        init(onAttempt: @escaping () -> Void) { self.onAttempt = onAttempt }

        func presentationControllerDidAttemptToDismiss(_ presentationController: UIPresentationController) {
            onAttempt()
        }

        /// Always allows the dismiss to proceed once attempted a second time
        /// through this delegate path — `.interactiveDismissDisabled` on the
        /// SwiftUI side remains the sole gate that blocks the *first* swipe;
        /// this observer never becomes a second, conflicting one.
        func presentationControllerShouldDismiss(_ presentationController: UIPresentationController) -> Bool {
            true
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
        private func attachDelegate() {
            var candidate: UIViewController? = self
            while let current = candidate {
                if current.presentingViewController != nil {
                    current.presentationController?.delegate = coordinator
                    return
                }
                candidate = current.parent
            }
        }
    }
}
