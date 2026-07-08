import XCTest
@testable import Tripto

/// `ToastOverlay.displayDuration(for:)` (UX audit finding 3) — a flat
/// two-second timer clipped longer toasts before they could be read while
/// padding out short ones. Regression net for the reading-time scaling,
/// mirroring `HomeRefreshFeedbackTests`' style.
final class ToastDurationTests: XCTestCase {
    func testShortMessageStaysAtFloor() {
        // "Flight added" is short enough that the scaled value would fall
        // under the 2.0s floor without the `max`.
        XCTAssertEqual(ToastOverlay.displayDuration(for: "Flight added"), 2.0)
    }

    func testRefreshFailureMessageScalesAboveFloor() {
        let message = "Couldn\u{2019}t refresh \u{2014} pull to try again"
        XCTAssertGreaterThanOrEqual(ToastOverlay.displayDuration(for: message), 2.8)
    }

    func testLongMessageIsCappedAtFourSeconds() {
        let message = String(repeating: "a", count: 200)
        XCTAssertEqual(ToastOverlay.displayDuration(for: message), 4.0)
    }

    func testDurationIsMonotonicallyNonDecreasingInLength() {
        let lengths = [0, 5, 13, 20, 36, 50, 100, 200, 400]
        let durations = lengths.map { ToastOverlay.displayDuration(for: String(repeating: "a", count: $0)) }
        for (previous, next) in zip(durations, durations.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next)
        }
    }
}
