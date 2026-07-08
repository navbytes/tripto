import SwiftUI
import UIKit

/// Restores the interactive edge-swipe-to-pop gesture that
/// `.toolbar(.hidden, for: .navigationBar)` disables (UX audit finding 1).
///
/// SwiftUI's `NavigationStack` is UIKit-backed by one shared
/// `UINavigationController` (see `TripRoute`'s doc comment on the app's
/// single stack, rooted in `HomeView`). Hiding that controller's nav bar via
/// `.toolbar(.hidden, for: .navigationBar)` — `TripView` does this for its
/// gradient hero — also breaks `interactivePopGestureRecognizer`'s default
/// delegate, which declines to begin the swipe whenever the bar is hidden.
/// Attaching this view anywhere in a hidden-bar screen's hierarchy installs
/// a small proxy delegate that says yes whenever there's somewhere to pop
/// *to* (`viewControllers.count > 1`, so the swipe can never mis-fire on the
/// stack's root), and restores UIKit's original delegate on teardown so
/// screens that never hide their bar are unaffected.
///
/// Deliberately not the common `extension UINavigationController { override
/// func viewDidLoad() }` swizzle-via-extension hack — overriding a UIKit
/// method from an extension is fragile (silently breaks if UIKit's own
/// dispatch changes internally) and would apply globally instead of only to
/// the screens that actually need it.
struct PopGestureRestorer: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> HostViewController {
        let controller = HostViewController()
        controller.coordinator = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: HostViewController, context: Context) {
        uiViewController.attach()
    }

    static func dismantleUIViewController(_ uiViewController: HostViewController, coordinator: Coordinator) {
        uiViewController.restore()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        weak var navigationController: UINavigationController?
        /// UIKit's own delegate, captured before this proxy takes over.
        /// Wrap-and-forward (same shape as `SheetDismissAttemptObserver`'s
        /// coordinator): this proxy answers only `gestureRecognizerShouldBegin`
        /// itself and relays every other selector back to UIKit's delegate,
        /// so behavior this type doesn't intentionally change (e.g.
        /// simultaneous-recognition rules) is preserved.
        weak var originalDelegate: UIGestureRecognizerDelegate?

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            (navigationController?.viewControllers.count ?? 0) > 1
        }

        override func responds(to aSelector: Selector!) -> Bool {
            super.responds(to: aSelector) || (originalDelegate?.responds(to: aSelector) ?? false)
        }

        override func forwardingTarget(for aSelector: Selector!) -> Any? {
            if super.responds(to: aSelector) { return nil }
            return originalDelegate
        }
    }

    final class HostViewController: UIViewController {
        var coordinator: Coordinator?
        /// The navigation controller this proxy is currently installed on
        /// — tracked so `restore()` (called once, from
        /// `dismantleUIViewController`) knows exactly where to put UIKit's
        /// original delegate back, even after this host has been removed
        /// from the hierarchy.
        private weak var attachedTo: UINavigationController?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            attach()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            attach()
        }

        func attach() {
            guard let coordinator else { return }
            guard let navigationController = parent?.navigationController ?? navigationController else { return }
            guard navigationController !== attachedTo else { return }
            guard let recognizer = navigationController.interactivePopGestureRecognizer else { return }

            coordinator.navigationController = navigationController
            if recognizer.delegate !== coordinator {
                coordinator.originalDelegate = recognizer.delegate
                recognizer.delegate = coordinator
            }
            attachedTo = navigationController
        }

        func restore() {
            guard let navigationController = attachedTo,
                let recognizer = navigationController.interactivePopGestureRecognizer,
                recognizer.delegate === coordinator
            else { return }
            recognizer.delegate = coordinator?.originalDelegate
        }
    }
}
