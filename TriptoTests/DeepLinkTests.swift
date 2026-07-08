import XCTest
@testable import Tripto

/// M3 brief: "Deep-link URL parsing: tripto://join/TOKEN and
/// https://tripto.navbytes.io/join/TOKEN both extract TOKEN;
/// garbage/paths without a token return nil; the /t/ share path is NOT
/// treated as an invite" + "Invite/share URL builders produce the exact
/// expected strings."
final class DeepLinkTests: XCTestCase {
    // MARK: - Parsing

    func testCustomSchemeExtractsToken() {
        let url = URL(string: "tripto://join/abc123def456")!
        XCTAssertEqual(DeepLink.inviteToken(from: url), "abc123def456")
    }

    func testUniversalLinkExtractsToken() {
        let url = URL(string: "https://tripto.navbytes.io/join/abc123def456")!
        XCTAssertEqual(DeepLink.inviteToken(from: url), "abc123def456")
    }

    func testHttpUniversalLinkExtractsTokenToo() {
        let url = URL(string: "http://tripto.navbytes.io/join/abc123def456")!
        XCTAssertEqual(DeepLink.inviteToken(from: url), "abc123def456")
    }

    func testSharePathIsNeverTreatedAsAnInviteViaCustomScheme() {
        let url = URL(string: "tripto://t/abc123def456")!
        XCTAssertNil(DeepLink.inviteToken(from: url))
    }

    func testSharePathIsNeverTreatedAsAnInviteViaUniversalLink() {
        let url = URL(string: "https://tripto.navbytes.io/t/abc123def456")!
        XCTAssertNil(DeepLink.inviteToken(from: url))
    }

    func testWrongHostReturnsNil() {
        let url = URL(string: "https://evil.example.com/join/abc123")!
        XCTAssertNil(DeepLink.inviteToken(from: url))
    }

    func testUnrelatedSchemeReturnsNil() {
        let url = URL(string: "mailto:join@tripto.navbytes.io")!
        XCTAssertNil(DeepLink.inviteToken(from: url))
    }

    func testMissingTokenReturnsNilForBothSchemes() {
        XCTAssertNil(DeepLink.inviteToken(from: URL(string: "tripto://join")!))
        XCTAssertNil(DeepLink.inviteToken(from: URL(string: "tripto://join/")!))
        XCTAssertNil(DeepLink.inviteToken(from: URL(string: "https://tripto.navbytes.io/join")!))
        XCTAssertNil(DeepLink.inviteToken(from: URL(string: "https://tripto.navbytes.io/join/")!))
    }

    func testRootPathReturnsNil() {
        XCTAssertNil(DeepLink.inviteToken(from: URL(string: "https://tripto.navbytes.io/")!))
        XCTAssertNil(DeepLink.inviteToken(from: URL(string: "https://tripto.navbytes.io")!))
    }

    func testExtraTrailingSegmentsReturnNil() {
        // A token never contains "/" — an extra path segment after it isn't
        // a shape this app recognizes as a valid invite link.
        XCTAssertNil(DeepLink.inviteToken(from: URL(string: "tripto://join/abc123/extra")!))
    }

    // MARK: - Building

    func testShareURLBuildsExactExpectedString() {
        XCTAssertEqual(
            DeepLink.shareURL(token: "abc123").absoluteString,
            "https://tripto.navbytes.io/t/abc123"
        )
    }

    func testInviteURLBuildsExactExpectedString() {
        XCTAssertEqual(
            DeepLink.inviteURL(token: "abc123").absoluteString,
            "https://tripto.navbytes.io/join/abc123"
        )
    }
}
