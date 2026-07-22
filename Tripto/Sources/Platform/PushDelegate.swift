import Foundation
import UIKit
import UserNotifications

/// T2 (`.claude/company/release-prep-push/BRIEF.md`, ROADMAP 3.3): the one
/// seam a pure-SwiftUI-lifecycle app still needs `UIApplicationDelegate`
/// for — APNs registration's callback-based result. `TriptoApp` wires this
/// in via `@UIApplicationDelegateAdaptor`; SwiftUI creates exactly one
/// instance for the app's lifetime and, since this conforms to `Observable`,
/// places it in the Environment automatically (so any View can read
/// `tappedTripId` via `@Environment(PushDelegate.self)` without `TriptoApp`
/// wiring it in by hand).
///
/// CRITICAL CONSTRAINT (T2 BRIEF): the App ID has no Push capability yet —
/// `registerForRemoteNotifications()` below fails gracefully
/// (`didFailToRegisterForRemoteNotificationsWithError`) on every build
/// until the owner adds the `aps-environment` entitlement later. Nothing
/// here assumes success.
@Observable
@MainActor
final class PushDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// `AuthManager`'s sign-in reupload isn't a View, so it can't reach
    /// this instance via `@Environment` — same "non-View code needs a way
    /// to reach an App-instantiated service" seam `AppServices.shared`
    /// already solves (see that type's own doc comment); `nil` is a state
    /// that invariant should rule out in practice (by the time a user can
    /// tap Sign in with Apple or the Settings toggle, `init()` below has
    /// already run), but callers still treat it defensively rather than
    /// force-unwrapping.
    private(set) static var shared: PushDelegate?

    /// Set by `didReceive response:` the moment a delivered push is
    /// tapped — `TriptoApp` observes this exactly like it observes
    /// `AppRouter.tripToOpen`: a plain value a View reacts to, so routing
    /// itself stays in the one place (`AppRouter.handleIncoming`) every
    /// other OS-event entry point (`.onOpenURL`, Spotlight) already goes
    /// through, rather than this delegate reaching into `AppRouter` itself.
    private(set) var tappedTripId: UUID?

    /// Only one registration is ever in flight at a time in practice (the
    /// Settings toggle awaits one call before allowing another tap; sign-in's
    /// silent refresh happens long before the app could show that toggle) —
    /// a second concurrent call would clobber this and strand the first
    /// continuation, so `registerForRemoteNotifications()` below isn't safe
    /// to call concurrently with itself.
    private var pendingRegistration: CheckedContinuation<Result<Data, Error>, Never>?

    override init() {
        super.init()
        Self.shared = self
        // Set as early as possible (earlier than `didFinishLaunching`) so a
        // cold launch via a notification tap is never missed.
        UNUserNotificationCenter.current().delegate = self
    }

    func clearTappedTripId() {
        tappedTripId = nil
    }

    /// Bridges `UIApplication.registerForRemoteNotifications()`'s
    /// callback-based result to async/await.
    func registerForRemoteNotifications() async -> Result<Data, Error> {
        await withCheckedContinuation { continuation in
            pendingRegistration = continuation
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        pendingRegistration?.resume(returning: .success(deviceToken))
        pendingRegistration = nil
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        pendingRegistration?.resume(returning: .failure(error))
        pendingRegistration = nil
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Foreground presentation (T2 SEAMS): banner + sound, same as a push
    /// delivered while backgrounded gets by default.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// A tap — foreground, background, or a cold launch via the
    /// notification itself (Apple's documented contract: this fires
    /// regardless of launch state once `UNUserNotificationCenter.delegate`
    /// is set, which `init()` above already does as early as possible).
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let tripId = PushPayload.tripId(from: response.notification.request.content.userInfo) {
            tappedTripId = tripId
        }
    }
}
