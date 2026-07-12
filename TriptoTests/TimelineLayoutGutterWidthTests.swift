import SwiftUI
import XCTest
@testable import Tripto

/// UX audit finding F1: `TimelineLayout.gutterWidth(for:)`'s stepped table
/// (tracking `Typo`'s own `UIFontMetrics(.body)` curve) — the old two-step
/// (44pt / 76pt) jump either clipped the zone label or wasted space at every
/// size in between. Pins the exact table plus its monotonicity, since a
/// future edit shrinking a step would silently reintroduce the clip this
/// finding fixed.
final class TimelineLayoutGutterWidthTests: XCTestCase {
    func testDefaultAndBelowStayAtTheOriginalFortyFourPoints() {
        for size: DynamicTypeSize in [.xSmall, .small, .medium, .large] {
            XCTAssertEqual(TimelineLayout.gutterWidth(for: size), 44, "\(size) should keep the original width")
        }
    }

    func testExactTableValuesAboveTheDefault() {
        XCTAssertEqual(TimelineLayout.gutterWidth(for: .xLarge), 50)
        XCTAssertEqual(TimelineLayout.gutterWidth(for: .xxLarge), 56)
        XCTAssertEqual(TimelineLayout.gutterWidth(for: .xxxLarge), 62)
    }

    func testEveryAccessibilitySizeUsesTheSameSeventySixPointCeiling() {
        for size: DynamicTypeSize in [
            .accessibility1, .accessibility2, .accessibility3, .accessibility4, .accessibility5
        ] {
            XCTAssertEqual(TimelineLayout.gutterWidth(for: size), 76, "\(size) must not exceed the AX ceiling")
        }
    }

    func testWidthIsMonotonicallyNonDecreasingAcrossTheFullSizeRange() {
        let widths = DynamicTypeSize.allCases.map { TimelineLayout.gutterWidth(for: $0) }
        for (previous, next) in zip(widths, widths.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next, "gutter width must never shrink as Dynamic Type size grows")
        }
    }

    func testIndentedLeadingTracksTheSameTableWithTheRailAndSpacingAdded() {
        let expected = TimelineLayout.gutterWidth(for: .xxLarge) + TimelineLayout.railWidth + Spacing.sm
        XCTAssertEqual(TimelineLayout.indentedLeading(for: .xxLarge), expected)
    }
}
