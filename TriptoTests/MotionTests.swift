import XCTest
import SwiftUI
@testable import Tripto

/// Pins the frozen Motion vocabulary (PLAN-signature-layer.md §D2) so a
/// drive-by "tune" of the spring family shows up as a failing test, not a
/// silent feel change across every consuming screen.
final class MotionTests: XCTestCase {
    func testSpringFamilyIsPinned() {
        XCTAssertEqual(Motion.snappy, Animation.spring(response: 0.25, dampingFraction: 0.90))
        XCTAssertEqual(Motion.standard, Animation.spring(response: 0.38, dampingFraction: 0.85))
        XCTAssertEqual(Motion.gentle, Animation.spring(response: 0.55, dampingFraction: 0.92))
        XCTAssertEqual(Motion.fade, Animation.easeInOut(duration: 0.18))
    }

    func testReduceMotionHelperReturnsNilUnderRM() {
        XCTAssertNil(Motion.m(Motion.standard, reduceMotion: true))
        XCTAssertEqual(Motion.m(Motion.standard, reduceMotion: false), Motion.standard)
    }
}
