import SwiftData
import SwiftUI

@main
struct TriptoApp: App {
    @Environment(\.scenePhase) private var scenePhase

    private let modelContainer: ModelContainer
    private let syncStatus: SyncStatus
    private let syncEngine: SyncEngine
    private let authManager: AuthManager

    init() {
        let container = AppSchema.makeContainer()
        let status = SyncStatus()
        let engine = SyncEngine(modelContainer: container, status: status)

        modelContainer = container
        syncStatus = status
        syncEngine = engine
        authManager = AuthManager(syncEngine: engine)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(authManager)
                .environment(syncStatus)
                .environment(\.syncEngine, syncEngine)
        }
        .modelContainer(modelContainer)
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await syncEngine.appDidBecomeActive() }
        }
    }
}
