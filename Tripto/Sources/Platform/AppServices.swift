import Foundation
import SwiftData

/// App-intents deepening (`.claude/company/app-intents/BRIEF.md`): the two
/// services an in-process `AppIntent` needs but can't reach through
/// SwiftUI's environment (`@Environment(\.modelContext)`/`\.syncEngine`
/// only exist once a `View` is on screen). `TriptoApp.init` assigns this
/// exactly once, right after building both — safe because an in-process
/// intent (`openAppWhenRun = false`, every intent in `Intents.swift`) still
/// cold-launches the app's process first if it isn't already running, so
/// `TriptoApp.init` has always already run by the time any intent's
/// `perform()` executes. `nil` is a state that invariant should rule out in
/// practice; every intent still treats it defensively (a friendly dialog,
/// never a crash) rather than assuming it.
///
/// Deliberately minimal — just the `ModelContainer` (for `.mainContext`,
/// the same main-thread context `@Environment(\.modelContext)` itself
/// resolves to, so an intent's write is visible immediately if the app
/// happens to already be foregrounded) and the `SyncEngine` (to enqueue
/// through the same offline-first outbox as every in-app write). No
/// `AuthManager`: `Supa.client.auth.currentSession` already reads the same
/// Keychain-backed session synchronously, with no dependency on
/// `AuthManager`'s async `authStateChanges` subscription having fired yet.
struct AppServices {
    static var shared: AppServices?

    let modelContainer: ModelContainer
    let syncEngine: SyncEngine
}
