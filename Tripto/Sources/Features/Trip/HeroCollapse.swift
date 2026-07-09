import SwiftUI

enum HeroCollapse {
    /// Points of upward scroll over which the hero goes fully expanded -> compact.
    static let collapseDistance: CGFloat = 120
    /// Reduced-motion snap point: past this, jump straight to compact.
    static let snapThreshold: CGFloat = 24
    /// Shared coordinate-space name every tab's ScrollView registers.
    static let scrollSpace = "tripHeroScroll"

    /// offset: positive = content scrolled up (hero should collapse). 0/negative
    /// (rubber-band at top) = fully expanded. Result clamped 0...1.
    static func progress(for offset: CGFloat, reduceMotion: Bool) -> Double {
        if reduceMotion { return offset > snapThreshold ? 1 : 0 }
        guard offset > 0 else { return 0 }
        return Double(min(offset / collapseDistance, 1))
    }
}

/// Set by each tab's ScrollView sentinel; read per-tab in TripView.tabContent.
struct HeroScrollOffsetKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// Zero-height sentinel placed as the FIRST child inside a tab's scroll content.
/// Reports how far that content has scrolled up, in the shared coordinate space.
struct HeroScrollSentinel: View {
    var body: some View {
        GeometryReader { geo in
            Color.clear.preference(
                key: HeroScrollOffsetKey.self,
                value: -geo.frame(in: .named(HeroCollapse.scrollSpace)).minY
            )
        }
        .frame(height: 0)
    }
}
