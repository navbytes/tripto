import AuthenticationServices
import XCTest
@testable import Tripto

/// `WelcomeView.signInFailureMessage`/`urlErrorCode` — the three §6.6
/// failure-copy buckets (offline / server unreachable / on-our-end), plus
/// `invitePreviewAnnouncement(for:)`'s resolved-states-only VoiceOver copy,
/// `appleSideFailureMessage(for:)`'s Settings-vs-transient split, and a pin
/// test on `signingInStatusText` so the rendered label and the VoiceOver
/// announcement can't silently drift.
/// Mirrors `PushErrorClassifierTests`' pure-function style.
final class SignInFailureMessageTests: XCTestCase {
    private struct OtherDomainError: Error {}

    // MARK: - signInFailureMessage

    func testOfflineURLErrorCodesReturnOfflineCopy() {
        let codes: [URLError.Code] = [
            .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff
        ]
        for code in codes {
            let message = WelcomeView.signInFailureMessage(for: URLError(code))
            XCTAssertTrue(message.contains("offline"), "expected offline copy for \(code), got \(message)")
        }
    }

    func testUnreachableServerURLErrorCodesReturnServerCopy() {
        let codes: [URLError.Code] = [.timedOut, .cannotConnectToHost, .secureConnectionFailed]
        for code in codes {
            let message = WelcomeView.signInFailureMessage(for: URLError(code))
            XCTAssertTrue(message.contains("reach the server"), "expected server copy for \(code), got \(message)")
        }
    }

    func testNonNetworkErrorReturnsOnOurEndCopy() {
        let message = WelcomeView.signInFailureMessage(for: OtherDomainError())
        XCTAssertTrue(message.contains("on our end"), "expected on-our-end copy, got \(message)")
    }

    func testNSURLErrorDomainNSErrorFallsBackThroughUrlErrorCode() {
        // Not a typed `URLError` — exercises `urlErrorCode`'s
        // `NSURLErrorDomain` fallback path the way an underlying network
        // failure wrapped in a different `Error` type would.
        let nsError = NSError(domain: NSURLErrorDomain, code: URLError.notConnectedToInternet.rawValue)
        XCTAssertEqual(WelcomeView.urlErrorCode(nsError), .notConnectedToInternet)
        let message = WelcomeView.signInFailureMessage(for: nsError)
        XCTAssertTrue(message.contains("offline"), "expected offline copy, got \(message)")
    }

    func testUrlErrorCodeIsNilForNonNetworkErrors() {
        XCTAssertNil(WelcomeView.urlErrorCode(OtherDomainError()))
    }

    // MARK: - invitePreviewAnnouncement

    func testIdleAndLoadingProduceNoAnnouncement() {
        XCTAssertNil(WelcomeView.invitePreviewAnnouncement(for: .idle))
        XCTAssertNil(WelcomeView.invitePreviewAnnouncement(for: .loading))
    }

    func testLoadedProducesAnnouncementWithInviterTripAndRole() {
        let preview = InvitePreview(
            role: "companion", tripTitle: "Lisbon", startDate: "2026-05-14",
            endDate: "2026-05-27", coverGradient: "dusk", inviterName: "Meera"
        )
        let announcement = WelcomeView.invitePreviewAnnouncement(for: .loaded(preview))
        XCTAssertNotNil(announcement)
        XCTAssertTrue(announcement!.contains("Meera"))
        XCTAssertTrue(announcement!.contains("Lisbon"))
        XCTAssertTrue(announcement!.contains("Companion"))
    }

    func testInvalidProducesExpiredLinkAnnouncement() {
        let announcement = WelcomeView.invitePreviewAnnouncement(for: .invalid)
        XCTAssertEqual(announcement, "This invite link has expired or been revoked. Ask for a new link.")
    }

    func testUnavailableProducesFallbackAnnouncement() {
        let announcement = WelcomeView.invitePreviewAnnouncement(for: .unavailable)
        XCTAssertEqual(announcement, "Couldn\u{2019}t load your invite details \u{2014} you can still sign in to join.")
    }

    // MARK: - isUserCancelledAppleSignIn

    func testAppleDomainCancelCodeIsSuppressed() {
        let error = NSError(domain: ASAuthorizationErrorDomain, code: ASAuthorizationError.canceled.rawValue)
        XCTAssertTrue(WelcomeView.isUserCancelledAppleSignIn(error))
    }

    func testSameCodeInOtherDomainIsNotSuppressed() {
        // The exact cross-domain code collision the domain check guards
        // against — a code-only check would have suppressed this too.
        let error = NSError(domain: "SomeOtherDomain", code: ASAuthorizationError.canceled.rawValue)
        XCTAssertFalse(WelcomeView.isUserCancelledAppleSignIn(error))
    }

    // MARK: - appleSideFailureMessage

    func testUnknownCodeReturnsSettingsPointingCopy() {
        let error = NSError(domain: ASAuthorizationErrorDomain, code: ASAuthorizationError.unknown.rawValue)
        let message = WelcomeView.appleSideFailureMessage(for: error)
        XCTAssertTrue(message.contains("Settings"), "expected Settings-pointing copy, got \(message)")
        XCTAssertFalse(message.contains("try again"), "unknown-code copy shouldn't suggest retrying, got \(message)")
    }

    func testTransientCodesReturnTryAgainCopy() {
        let codes: [ASAuthorizationError.Code] = [.failed, .invalidResponse, .notHandled]
        for code in codes {
            let error = NSError(domain: ASAuthorizationErrorDomain, code: code.rawValue)
            let message = WelcomeView.appleSideFailureMessage(for: error)
            XCTAssertTrue(message.contains("try again"), "expected transient copy for \(code), got \(message)")
        }
    }

    func testUnknownCodeInOtherDomainIsNotSuppressed() {
        // Mirrors `testSameCodeInOtherDomainIsNotSuppressed` — the exact
        // cross-domain code collision the domain check guards against.
        let error = NSError(domain: "SomeOtherDomain", code: ASAuthorizationError.unknown.rawValue)
        let message = WelcomeView.appleSideFailureMessage(for: error)
        XCTAssertTrue(message.contains("try again"), "expected transient copy, got \(message)")
        XCTAssertFalse(message.contains("Settings"), "expected transient copy, not Settings copy, got \(message)")
    }

    // MARK: - signingInStatusText

    func testSigningInStatusTextIsPinned() {
        // Pins the exact string so the rendered `Text` and the VoiceOver
        // announcement in `WelcomeView.body` — both sourced from this
        // constant — can't silently drift.
        XCTAssertEqual(WelcomeView.signingInStatusText, "Signing you in\u{2026}")
    }
}
