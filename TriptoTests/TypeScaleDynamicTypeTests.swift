import XCTest
import UIKit
@testable import Tripto

/// Accessibility: the custom Fraunces/Sofia type scale must grow with the
/// user's Dynamic Type setting the way system text styles do. The original
/// `Typo` built fixed-size `UIFont`s (no `UIFontMetrics`), so text never
/// scaled — a low-vision user maxing "Larger Text" saw no change on the core
/// screens. These lock in that the scale now honors Dynamic Type, while NOT
/// inflating at the default content size.
final class TypeScaleDynamicTypeTests: XCTestCase {
    private func trait(_ category: UIContentSizeCategory) -> UITraitCollection {
        UITraitCollection(preferredContentSizeCategory: category)
    }

    // `.large` is iOS's default content size category — the scale must be a
    // no-op there so nothing changes for users on default settings.
    func testBodyUnchangedAtDefaultContentSize() {
        let font = Typo.resolvedUIFont(
            familyKeyword: "Sofia Sans", size: 16, weight: .regular,
            textStyle: .body, compatibleWith: trait(.large)
        )
        XCTAssertEqual(font.pointSize, 16, accuracy: 0.5,
                       "at the default text size the type scale must not inflate")
    }

    func testBodyScalesUpAtMaxAccessibilitySize() {
        let base: CGFloat = 16
        let big = Typo.resolvedUIFont(
            familyKeyword: "Sofia Sans", size: base, weight: .regular,
            textStyle: .body, compatibleWith: trait(.accessibilityExtraExtraExtraLarge)
        )
        XCTAssertGreaterThan(big.pointSize, base + 6,
                             "body type must scale up substantially at the largest accessibility size")
    }

    func testDisplayStyleAlsoScales() {
        let base: CGFloat = 30
        let big = Typo.resolvedUIFont(
            familyKeyword: "Fraunces", size: base, weight: .semibold,
            textStyle: .title2, compatibleWith: trait(.accessibilityExtraExtraExtraLarge)
        )
        XCTAssertGreaterThan(big.pointSize, base + 4, "display titles must scale with Dynamic Type too")
    }

    func testMonospacedCodeScales() {
        let big = Typo.resolvedMonoUIFont(
            size: 14.5, compatibleWith: trait(.accessibilityExtraExtraExtraLarge)
        )
        XCTAssertGreaterThan(big.pointSize, 14.5 + 5, "monospaced confirmation-code type must scale too")
    }
}
