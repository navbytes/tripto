import CoreSpotlight
import SwiftData
import SwiftUI

@main
struct TriptoApp: App {
    @Environment(\.scenePhase) private var scenePhase
    /// T2 (ROADMAP 3.3): the one `UIApplicationDelegate` seam this
    /// otherwise pure-SwiftUI-lifecycle app needs, for APNs registration's
    /// callback-based result (`PushDelegate`'s own doc comment). SwiftUI
    /// creates and owns the single instance; no manual wiring needed here
    /// beyond declaring the property.
    @UIApplicationDelegateAdaptor private var appDelegate: PushDelegate

    private let modelContainer: ModelContainer
    private let syncStatus: SyncStatus
    private let syncEngine: SyncEngine
    private let authManager: AuthManager
    private let appRouter: AppRouter

    init() {
        let container = AppSchema.makeContainer()
        let status = SyncStatus()
        let engine = SyncEngine(modelContainer: container, status: status)

        modelContainer = container
        syncStatus = status
        syncEngine = engine
        authManager = AuthManager(syncEngine: engine)
        appRouter = AppRouter()

        // App-intents deepening: publishes the seam `AddToPackingIntent`/
        // `ConfirmationCodeIntent` (Platform/Intents.swift) read — see
        // `AppServices`'s own doc comment for why assigning it here, once,
        // is safe for an in-process intent.
        AppServices.shared = AppServices(modelContainer: container, syncEngine: engine)

        // PLAN-signature-layer.md §D7: Spotlight indexing attaches to the
        // frozen `onWrite` hook — same moment, same debounce as every other
        // glanceable surface (§D6 "one pipeline"). Fire-and-forget from
        // `init` (the same pattern `AuthManager` itself uses to kick off
        // `syncEngine.start()`) since `setOnWrite` is an actor method and
        // `init` can't `await`; the 800ms write debounce means this wins the
        // race against any real write in practice.
        Task { await engine.snapshotWriter.setOnWrite(SpotlightIndexer.handle) }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)
                .environment(syncStatus)
                .environment(\.syncEngine, syncEngine)
                .environment(appRouter)
                .onOpenURL { url in
                    // Real entry point for `tripto://join/<token>` and
                    // `https://tripto.navbytes.io/join/<token>` (M3 brief),
                    // plus `tripto://trip/<uuid>` (PLAN-signature-layer.md
                    // §D6 — widget taps) — the verify drill's `xcrun simctl
                    // openurl` exercises this exact same callback, nothing
                    // simulated.
                    appRouter.handleIncoming(url: url, isSignedIn: authManager.isSignedIn)
                }
                .onContinueUserActivity(CSSearchableItemActionType) { activity in
                    // §D7: a Spotlight trip result tap arrives as this
                    // activity, identifier at `CSSearchableItemActivityIdentifier`
                    // (research §4). Rebuilt as the same `tripto://trip/<uuid>`
                    // shape a widget tap uses and handed to the identical
                    // `handleIncoming` entry point above — one route-in path,
                    // literally, not just in spirit.
                    guard
                        let identifier = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String,
                        let url = URL(string: "tripto://trip/\(identifier)")
                    else { return }
                    appRouter.handleIncoming(url: url, isSignedIn: authManager.isSignedIn)
                }
                // T2: a delivered push's tap (`PushDelegate.tappedTripId`,
                // set by its `UNUserNotificationCenterDelegate` callback) —
                // reuses the exact `tripto://trip/<uuid>` shape and
                // signed-in gate the Spotlight continuation above already
                // does, rather than adding a second route-in entry point to
                // `AppRouter`.
                .onChange(of: appDelegate.tappedTripId) { _, tripId in
                    defer { appDelegate.clearTappedTripId() }
                    guard let tripId, let url = URL(string: "tripto://trip/\(tripId.uuidString)") else { return }
                    appRouter.handleIncoming(url: url, isSignedIn: authManager.isSignedIn)
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                Task { await syncEngine.appDidBecomeActive() }
            case .background:
                // PLAN-signature-layer.md §D6: catch-all + freshness before
                // the user leaves — debounced like every other hook
                // (`SnapshotWriter.notifyDataChanged()`), not a forced
                // synchronous write.
                Task { await syncEngine.snapshotWriter.notifyDataChanged() }
            default:
                break
            }
        }
    }
}
