import XCTest
@testable import Tripto

/// T2 (`.claude/company/release-prep-push/BRIEF.md`, ROADMAP 3.3) — the pure
/// pieces of the Suggestion-alerts push flow: token hex-encoding, payload
/// parsing, and the toggle's outcome -> message/revert decisions. The
/// side-effecting half (`SuggestionAlertsToggle.enable`/`disable`/
/// `silentlyRefreshToken`, `PushDelegate`) touches real APNs/`Supa.client`
/// APIs and is exercised live, not here — same split as
/// `LiveActivityCoordinatorTests` vs. `LiveActivityCoordinator.evaluate()`.
final class SuggestionAlertsTests: XCTestCase {
    // MARK: - PushTokenEncoding

    func testHexStringEncodesEachByteAsTwoLowercaseDigits() {
        let data = Data([0x00, 0x0A, 0xFF, 0x42])
        XCTAssertEqual(PushTokenEncoding.hexString(data), "000aff42")
    }

    func testHexStringOfEmptyDataIsEmptyString() {
        XCTAssertEqual(PushTokenEncoding.hexString(Data()), "")
    }

    // MARK: - PushPayload

    func testTripIdParsesAValidUUIDString() {
        let id = UUID()
        let userInfo: [AnyHashable: Any] = ["tripId": id.uuidString]
        XCTAssertEqual(PushPayload.tripId(from: userInfo), id)
    }

    func testTripIdReturnsNilWhenKeyMissing() {
        XCTAssertNil(PushPayload.tripId(from: [:]))
    }

    func testTripIdReturnsNilForMalformedUUID() {
        XCTAssertNil(PushPayload.tripId(from: ["tripId": "not-a-uuid"]))
    }

    func testTripIdReturnsNilForNonStringValue() {
        XCTAssertNil(PushPayload.tripId(from: ["tripId": 12345]))
    }

    // MARK: - SuggestionAlertsToggle state machine

    func testAuthorizedOutcomeHasNoFailureMessageAndDoesNotRevert() {
        let outcome = SuggestionAlertsOutcome.authorized(tokenHex: "abcd")
        XCTAssertNil(SuggestionAlertsToggle.failureMessage(for: outcome))
        XCTAssertFalse(SuggestionAlertsToggle.shouldRevertToOff(for: outcome))
    }

    func testDeniedOutcomeNamesSettingsAsTheFixAndReverts() {
        let message = SuggestionAlertsToggle.failureMessage(for: .denied)
        XCTAssertEqual(message, "Notifications are off. Turn them on in Settings \u{2192} Tripto to get suggestion alerts.")
        XCTAssertTrue(SuggestionAlertsToggle.shouldRevertToOff(for: .denied))
    }

    func testRegistrationFailedOutcomeNamesTheBuildAndReverts() {
        let message = SuggestionAlertsToggle.failureMessage(for: .registrationFailed)
        XCTAssertEqual(message, "Couldn\u{2019}t turn on notifications on this build.")
        XCTAssertTrue(SuggestionAlertsToggle.shouldRevertToOff(for: .registrationFailed))
    }
}
