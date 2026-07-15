import Nuke

/// Nuke pipeline setup (plan D6): a `DataCache`-backed pipeline so a synced
/// avatar photo persists across relaunch/offline — Nuke's own out-of-the-box
/// default pipeline (what `LazyImage` uses absent this) only caches in
/// memory, which is exactly the gap `AsyncImage`/`URLCache` can't close
/// either (the whole reason this app takes on Nuke as a dependency — plan
/// D6). `LazyImage` reads `ImagePipeline.shared` unless told otherwise, so
/// swapping it once, before the first avatar photo ever renders, is the one
/// integration point this app needs — no `.environment(\.imagePipeline:)`
/// plumbing anywhere.
enum AvatarImagePipeline {
    /// A stored `static let` runs its initializer exactly once, the first
    /// time anything reads it (thread-safe, no manual `dispatch_once`) —
    /// `AvatarPhotoCircle.body` reads this before building its `LazyImage`
    /// so the swap always happens before any photo load starts.
    static let configured: Bool = {
        // `.withDataCache()` (Nuke 13's actual signature — a `name`/
        // `sizeLimit` pair, not a `dataCachePolicy:` argument) already wires
        // up a real `DataCache` with its own 150MB default limit and
        // disables the redundant HTTP `URLCache`; `.automatic` (over the
        // default `.storeOriginalData`) is set explicitly since this app's
        // avatar `LazyImage` requests carry no processors either way, `.automatic`
        // is the policy Nuke's own docs recommend reaching for by default.
        var configuration = ImagePipeline.Configuration.withDataCache()
        configuration.dataCachePolicy = .automatic
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
        return true
    }()
}
