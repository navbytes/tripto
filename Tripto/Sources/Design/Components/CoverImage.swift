import Nuke
import NukeUI
import SwiftUI

/// The one place a trip cover PHOTO actually renders (plan D6: "photos wrap
/// the existing one-seam renders") — every existing `CoverGradient.from(key:)`
/// call site (`TripCard`, the hero-flight clone in `HeroFlight.swift`,
/// `HeroCollapse`'s hero background, `BeenRow`'s thumb) swaps to this
/// instead. The gradient always renders FIRST — the immediate placeholder
/// AND the permanent, offline-never-blank fallback, same contract as
/// `AvatarPhotoCircle` (`AvatarStack.swift`) — with a Nuke `LazyImage`
/// layered on top that only ever covers it on a successful load. `nil`
/// `coverImagePath` (every trip before P8b, unaffected) renders exactly the
/// old bare gradient.
///
/// Deliberately not a fixed shape/frame of its own (unlike `AvatarPhotoCircle`,
/// always a circle at one `diameter`) — callers render this at very
/// different sizes (a card, a full-bleed hero, a 44pt thumb) and already
/// apply their own `.frame`/`.clipShape` right after the gradient-only
/// render this replaces; this view just fills whatever size its container
/// proposes, same as the gradient alone always has. Any scrim a call site
/// layers on top (`CoverGradient.textScrim`) stays a later, separate
/// modifier/sibling at that call site — it composites over this view's
/// output the same way it always composited over the bare gradient, so
/// title contrast holds over a photo exactly like it does over a gradient.
struct CoverImage: View {
    let coverGradientKey: String
    let coverImagePath: String?
    /// `BeenRow`'s 44pt thumb (P8a precedent — see `AvatarPhotoCircle`'s
    /// `.processors([ImageProcessors.Resize(...)])` doc comment): decoding a
    /// list thumbnail at the full stored size (~1600px here) is the same
    /// "never decode bigger than you'll render" waste avatars already avoid.
    /// `nil` (every other call site — a card/hero, already much closer to
    /// the stored bound) skips the processor.
    var resizeTo: CGSize?

    var body: some View {
        ZStack {
            CoverGradient.from(key: coverGradientKey)
            // `AppImagePipeline.configured` swaps in the DataCache-backed
            // pipeline `LazyImage` reads by default, exactly once, before
            // the first photo load this app ever attempts (avatar or cover).
            if let coverImagePath, AppImagePipeline.configured, let url = CoverStorage.publicURL(for: coverImagePath) {
                photo(url: url)
            }
        }
        // Option A hero fix: bounds the WHOLE composed view (gradient +
        // photo), not just the photo's own inner `.clipped()` above — a
        // Nuke `LazyImage` with no explicit `.frame()` ahead of it (this
        // view is deliberately frame-less, see the doc comment above) can
        // still report/paint past whatever frame a caller assigns it, same
        // as Nuke's own docs always pair `LazyImage` with an external
        // `.frame().clipped()`. Every existing caller already bounds this
        // view externally (`.frame`/`.clipShape` right after the call
        // site), so this internal clip is a no-op for them; it's the ONE
        // caller that skips its own bound (`HeroCollapse`'s `.background`,
        // which relies on `.ignoresSafeArea(edges: .top)` sizing instead of
        // a frame/clipShape) that this protects.
        .clipped()
    }

    @ViewBuilder
    private func photo(url: URL) -> some View {
        if let resizeTo {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                }
                // `.empty`/`.failure` intentionally render nothing — the
                // gradient underneath already shows through, same contract
                // as `AvatarPhotoCircle`.
            }
            .processors([ImageProcessors.Resize(size: resizeTo, contentMode: .aspectFill, crop: true)])
            .clipped()
        } else {
            LazyImage(url: url) { state in
                if let image = state.image {
                    image.resizable().scaledToFill()
                }
            }
            .clipped()
        }
    }
}

#Preview {
    VStack(spacing: Spacing.lg) {
        CoverImage(coverGradientKey: "dusk", coverImagePath: nil)
            .frame(height: 120)
            .clipShape(RoundedRectangle(cornerRadius: Radii.cover, style: .continuous))
        CoverImage(coverGradientKey: "plum", coverImagePath: nil, resizeTo: CGSize(width: 44, height: 44))
            .frame(width: 44, height: 44)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    .padding(Spacing.xl)
    .background(Palette.paper)
}
