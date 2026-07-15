import Nuke

/// Nuke pipeline setup (plan D6): a `DataCache`-backed pipeline so a synced
/// photo persists across relaunch/offline — Nuke's own out-of-the-box
/// default pipeline (what `LazyImage` uses absent this) only caches in
/// memory, which is exactly the gap `AsyncImage`/`URLCache` can't close
/// either (the whole reason this app takes on Nuke as a dependency — plan
/// D6). `LazyImage` reads `ImagePipeline.shared` unless told otherwise, so
/// swapping it once, before the first photo of ANY kind ever renders, is the
/// one integration point this app needs — no `.environment(\.imagePipeline:)`
/// plumbing anywhere.
///
/// P8b (photo trip covers): originally `AvatarImagePipeline` (P8a) — renamed
/// since this configures the one process-wide `ImagePipeline.shared` every
/// `LazyImage` reads, avatar or cover; there was never anything
/// avatar-specific in it besides the old name. `AvatarPhotoCircle.body`
/// (avatars) and `CoverImage.body` (covers) both read `configured` before
/// building their own `LazyImage`.
enum AppImagePipeline {
    /// A stored `static let` runs its initializer exactly once, the first
    /// time anything reads it (thread-safe, no manual `dispatch_once`) — so
    /// the swap always happens before any photo load starts, regardless of
    /// which call site gets there first.
    static let configured: Bool = {
        // `.withDataCache()` (Nuke 13's actual signature — a `name`/
        // `sizeLimit` pair, not a `dataCachePolicy:` argument) already wires
        // up a real `DataCache` with its own 150MB default limit and
        // disables the redundant HTTP `URLCache`; `.automatic` (over the
        // default `.storeOriginalData`) is set explicitly since this app's
        // avatar/cover `LazyImage` requests carry no processors either way
        // (or only a decode-time resize, never a re-encode), `.automatic`
        // is the policy Nuke's own docs recommend reaching for by default.
        var configuration = ImagePipeline.Configuration.withDataCache()
        configuration.dataCachePolicy = .automatic
        ImagePipeline.shared = ImagePipeline(configuration: configuration)
        return true
    }()
}
