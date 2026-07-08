import AuthenticationServices
import XCTest
@testable import Tripto

/// `WelcomeView.signInFailureMessage`/`urlErrorCode` — the three §6.6
/// failure-copy buckets (offline / server unreachable / on-our-end), plus
/// `invitePreviewAnnouncement(for:)`'s resolved-states-only VoiceOver copy.
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
}
