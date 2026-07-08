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

    /// UX audit finding 3 (round 2): the app's own longest shipped
    /// message — the signed-out edit toast (`TripView`'s hero-pencil edit
    /// path) — must get its full scaled duration, not the old 4.0s cap
    /// that used to clip it.
    func testSignedOutEditToastGetsItsFullScaledDuration() {
        let message = "Changes saved on this device \u{2014} you\u{2019}re signed out, so they " +
            "won\u{2019}t sync until you sign back in."
        XCTAssertEqual(message.count, 92)
        XCTAssertEqual(ToastOverlay.displayDuration(for: message), 6.26, accuracy: 0.01)
    }

    func testVeryLongMessageIsCappedAtEightSeconds() {
        let message = String(repeating: "a", count: 400)
        XCTAssertEqual(ToastOverlay.displayDuration(for: message), 8.0)
    }

    func testDurationIsMonotonicallyNonDecreasingInLength() {
        let lengths = [0, 5, 13, 20, 36, 50, 100, 200, 400, 800]
        let durations = lengths.map { ToastOverlay.displayDuration(for: String(repeating: "a", count: $0)) }
        for (previous, next) in zip(durations, durations.dropFirst()) {
            XCTAssertLessThanOrEqual(previous, next)
        }
    }
}
