import SwiftUI

/// `SyncEngine` is an `actor`, not an `@Observable` class, so it can't ride
/// along with the `.environment(_:)`/`@Environment(Type.self)` shorthand
/// (that requires `Observable` conformance for change tracking). Views
/// don't need to *observe* the engine anyway — only call its methods — so
/// a plain `EnvironmentKey` is the right tool: it hands down the reference
/// without asking the engine to be something it structurally isn't.
/// `SyncStatus` is the `@Observable` object views actually watch for
/// offline/pending state.
private struct SyncEngineKey: EnvironmentKey {
    static let defaultValue: SyncEngine? = nil
}

extension EnvironmentValues {
    var syncEngine: SyncEngine? {
        get { self[SyncEngineKey.self] }
        set { self[SyncEngineKey.self] = newValue }
    }
}
