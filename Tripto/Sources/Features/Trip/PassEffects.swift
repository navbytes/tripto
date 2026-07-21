import Foundation
import SwiftUI

/// Pure math + small view plumbing for `BookingDetailView`'s boarding-pass
/// physicality (PLAN-signature-layer.md §D3): scroll-based tilt/sheen, the
/// travel-day tear-off's drag math, and the torn-stub's persisted state.
/// Kept free of `ItineraryItem`-specific rendering — `BookingDetailView`
/// owns all the actual view wiring (gestures, animations, layout); this
/// file owns everything that can be a deterministic, testable function of
/// its inputs.
enum PassEffects {
    // MARK: - Scroll tilt + sheen

    /// Named coordinate space `BookingDetailView`'s `ScrollView` measures
    /// against — same iOS 17 `.coordinateSpace(.named(_:))` +
    /// `GeometryReader` recipe `HeroCollapse.heroScrollTracking` uses.
    static let scrollSpace = "bookingScroll"

    /// Hard cap from the plan: the pass never tilts more than this in
    /// either direction, however far the card has scrolled.
    static let maxTiltDegrees: Double = 3
    /// Points of scroll travel that map to the full ±3° — a tuning knob,
    /// not a contract value.
    private static let tiltSensitivityPoints: CGFloat = 140

    /// -1...1, clamped: 0 at rest, negative as the pass card scrolls up
    /// toward leaving the top of the screen, positive on rubber-band
    /// overscroll. The one shared "how far has this scrolled" signal both
    /// the tilt and the header sheen key off.
    static func scrollProgress(minY: CGFloat) -> Double {
        max(-1, min(1, Double(minY) / Double(tiltSensitivityPoints)))
    }

    /// Scroll-based tilt (not CoreMotion — battery-free, no permission,
    /// deterministic in screenshots/tests), clamped to `maxTiltDegrees`.
    static func tiltDegrees(minY: CGFloat) -> Double {
        scrollProgress(minY: minY) * maxTiltDegrees
    }

    /// The sheen's rest-position origin (the old `sheenStart(progress: 0)`).
    /// Gradient headers only (flight/hotel/transport) — `simpleHeader`'s
    /// light background has no sheen.
    static let sheenRestStart = UnitPoint(x: 0.2, y: -0.05)

    /// How much the sheen layer is oversized so its `sheenOffset` slide
    /// never reveals an edge inside the header's clip (max |offset| is
    /// 0.35 × width / 0.2 × height — 1.75× covers both with margin).
    static let sheenOverscan: CGFloat = 1.75

    /// Render-path replacement for the old sliding `UnitPoint` start: the
    /// same ±0.35-width / ±0.2-height travel as a layer translation, driven
    /// by `scrollProgress` inside a `.visualEffect`. Pure — see
    /// PassEffectsTests.
    static func sheenOffset(progress: Double, size: CGSize) -> CGSize {
        let clamped = max(-1, min(1, progress))
        return CGSize(width: -clamped * 0.35 * size.width, height: -clamped * 0.2 * size.height)
    }

    // MARK: - Travel-day trigger

    /// PLAN-signature-layer.md §D3: flights only, and only when
    /// device-local today is the item's own start day in the item's own
    /// zone — "the same day math the timeline uses"
    /// (`ItineraryTimeZone.localDay`/`item.startLocalDay`), compared as
    /// plain `DayDate`s so neither side needs to agree on a timezone.
    static func isTravelDay(item: ItineraryItem, today: DayDate = .today(calendar: .current)) -> Bool {
        item.category == .flight && item.startLocalDay == today
    }

    // MARK: - Tear-off drag math (pure; see PassEffectsTests)

    /// Drag distance (pt) that counts as a completed tear.
    static let tearThreshold: CGFloat = 96
    /// The stub's `offset.x` lags the finger by this factor while dragging
    /// (a rubber-band, not 1:1 tracking).
    static let tearRubberBand: CGFloat = 0.5
    /// Rotation never exceeds this while dragging (anchored at the leading
    /// perforation notch).
    static let tearMaxRotationDegrees: Double = 6
    /// `Haptics.tick` fires once each time drag progress first crosses
    /// these two fractions of `tearThreshold`.
    static let tearTick30Progress: Double = 0.3
    static let tearTick60Progress: Double = 0.6
    /// Where a detached stub comes to rest, and its resting tilt (eased
    /// down from `tearDetachRotationDegrees` right after the detach lands).
    static let tearDetachOffsetX: CGFloat = 40
    static let tearDetachOffsetY: CGFloat = 14
    static let tearDetachRotationDegrees: Double = 8
    static let tearRestRotationDegrees: Double = 1

    /// 0...1 (and beyond 1 for an over-drag past the threshold before
    /// release — callers that need a hard ceiling, e.g. rotation, clamp
    /// separately). Negative translation (dragging back toward/past the
    /// anchor) never reverses a tear — a real perforation doesn't
    /// un-tear — so it floors at 0.
    static func tearProgress(translation: CGFloat) -> Double {
        guard translation > 0 else { return 0 }
        return Double(translation / tearThreshold)
    }

    /// Rubber-banded horizontal offset for the stub while live-dragging.
    static func tearOffsetX(translation: CGFloat) -> CGFloat {
        max(0, translation) * tearRubberBand
    }

    /// Rotation while live-dragging, capped at `tearMaxRotationDegrees`
    /// even past the threshold.
    static func tearRotationDegrees(translation: CGFloat) -> Double {
        min(1, tearProgress(translation: translation)) * tearMaxRotationDegrees
    }

    static func hasReachedDetachThreshold(translation: CGFloat) -> Bool {
        translation >= tearThreshold
    }

    /// The dashed rule's gap width (pt), widening from the pass's normal
    /// resting `4` as the tear progresses — "the dash gap visually opens."
    /// `progress` is clamped 0...1 so an over-drag or the fully-torn resting
    /// state (`progress: 1`) never overshoots the widened gap.
    static func dashGapWidth(progress: Double) -> CGFloat {
        4 + CGFloat(max(0, min(1, progress))) * 16
    }

    // MARK: - Torn-stub persistence

    // ponytail: stale keys from past travel days are never deleted — a
    // handful of bytes per flight ever torn, across this device only, not
    // worth a cleanup pass.
    /// One `UserDefaults` bool per item+day — self-expiring by
    /// construction (a new travel day is simply a key that's never been
    /// set), so there is nothing to reset when the day rolls over.
    static func tornStubKey(itemId: UUID, day: DayDate) -> String {
        "tornStub.\(itemId.uuidString).\(day.stringValue)"
    }

    static func isTornStub(itemId: UUID, day: DayDate, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: tornStubKey(itemId: itemId, day: day))
    }

    static func setTornStub(_ torn: Bool, itemId: UUID, day: DayDate, defaults: UserDefaults = .standard) {
        defaults.set(torn, forKey: tornStubKey(itemId: itemId, day: day))
    }
}

// (measuringMinY View helper deleted 2026-07-21: the tilt/sheen moved onto
// `.visualEffect` — render-path geometry, no per-frame @State writes. See
// BookingDetailView.passEffectsEnabled's doc comment for the jank story.)
