import SwiftUI

/// Auth gate (M1): `WelcomeView` <-> `HomeView`, keyed off `AuthManager`.
/// `isRestoring` covers the brief window before the very first
/// `authStateChanges` event tells us whether a Keychain-persisted session
/// exists — showing nothing (rather than flashing `WelcomeView`) avoids a
/// visible sign-in-screen flicker for an already-signed-in user.
struct RootView: View {
    @Environment(AuthManager.self) private var authManager

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
        .modelContainer(container)
}
