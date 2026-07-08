import SwiftData
import SwiftUI

@main
struct TriptoApp: App {
    @Environment(\.scenePhase) private var scenePhase

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
                    // `https://tripto.navbytes.io/join/<token>` (M3 brief) —
                    // the verify drill's `xcrun simctl openurl` exercises
                    // this exact same callback, nothing simulated.
                    appRouter.handleIncoming(url: url, isSignedIn: authManager.isSignedIn)
                }
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await syncEngine.appDidBecomeActive() }
        }
    }
}
