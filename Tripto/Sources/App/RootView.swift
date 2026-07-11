import SwiftUI

/// Auth gate (M1): `WelcomeView` <-> `HomeView`, keyed off `AuthManager`.
/// `isRestoring` covers the brief window before the very first
/// `authStateChanges` event tells us whether a Keychain-persisted session
/// exists — showing nothing (rather than flashing `WelcomeView`) avoids a
/// visible sign-in-screen flicker for an already-signed-in user.
struct RootView: View {
    @Environment(AuthManager.self) private var authManager
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Palette.paper.ignoresSafeArea()

            if authManager.isRestoring {
                EmptyView()
            } else if authManager.isSignedIn {
                HomeView()
            } else {
                WelcomeView()
            }

            #if DEBUG
            FontCheck()
            #endif
        }
        // PLAN-signature-layer.md §D6: a Live Activity can only ever be
        // started in the foreground (research §1 — `Activity.request`
        // throws from the background), so foreground is the one moment
        // that matters. Needs no `isSignedIn` guard of its own: signed out
        // means `TripSnapshot.load()` returns nil (wiped on sign-out), so
        // `evaluate()` naturally has nothing to start.
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            Task { await LiveActivityCoordinator.evaluate() }
        }
    }
}

#Preview {
    let container = AppSchema.makeContainer(inMemory: true)
    let status = SyncStatus()
    let engine = SyncEngine(modelContainer: container, status: status)
    let auth = AuthManager(syncEngine: engine)

    return RootView()
        .environment(auth)
        .environment(status)
        .environment(\.syncEngine, engine)
        .environment(AppRouter())
        .modelContainer(container)
}
