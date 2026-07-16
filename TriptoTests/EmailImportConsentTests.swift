import XCTest
@testable import Tripto

/// Email-import consent gate (A5, `docs/BACKLOG.md`; Apple Guideline
/// 5.1.2(i)) — mirrors `AIImportConsentTests` exactly in shape, but for
/// `EmailImportConsent`'s address-FETCH decision instead of a send action
/// (see `EmailImportConsent`'s doc comment, `TripImportAddress.swift`, for
/// why the gated moment differs: email import has no in-app send moment to
/// gate, so this gates revealing the address instead).
///
/// `TripImportAddress.fetch` — the only call site that actually reaches the
/// network — is reachable from exactly two places (mirroring
/// `AIImportConsentTests`' own reachability argument): `ImportAddressLoader.fetchIfNeeded`'s
/// `.fetchImmediately` branch, and `grantEmailImportConsentAndFetch()` (the
/// consent dialog's "Continue" button, which calls `grant()` immediately
/// before re-fetching). So exercising `fetchDecision`/`grant`/`isGranted`
/// here is a complete, network-free proof of the gate decision — no UI test
/// needed.
///
/// Same injectable-`UserDefaults` recipe as `AIImportConsentTests`, so this
/// never touches the real `UserDefaults.standard`.
final class EmailImportConsentTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "EmailImportConsentTests")
        defaults.removePersistentDomain(forName: "EmailImportConsentTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "EmailImportConsentTests")
        defaults = nil
        super.tearDown()
    }

    func testNotGrantedByDefault() {
        XCTAssertFalse(EmailImportConsent.isGranted(defaults: defaults))
    }

    /// Requirement: "not-granted ⇒ address not fetched until accept" — a
    /// first-ever visit must show the pre-consent card, not fetch.
    /// `ImportAddressLoader.fetchIfNeeded` (shared by all three surfaces)
    /// only calls `TripImportAddress.fetch` on `.fetchImmediately`.
    func testFetchDecisionNeedsConsentWhenNotGranted() {
        XCTAssertEqual(EmailImportConsent.fetchDecision(defaults: defaults), .needsConsent)
    }

    /// Requirement: "accept records consent + proceeds" — `grant()` flips
    /// the flag, and the next fetch decision now fetches immediately.
    /// `ImportAddressCard`'s dialog "Continue" button calls exactly
    /// `onConsentGranted()`, which both surfaces wire to
    /// `grant()` + an immediate re-fetch, in that order.
    func testGrantRecordsConsentAndFetchDecisionThenFetchesImmediately() {
        EmailImportConsent.grant(defaults: defaults)
        XCTAssertTrue(EmailImportConsent.isGranted(defaults: defaults))
        XCTAssertEqual(EmailImportConsent.fetchDecision(defaults: defaults), .fetchImmediately)
    }

    /// Requirement: "already-granted ⇒ no re-prompt" (per install, not per
    /// session) — a second, independent `UserDefaults` instance backed by
    /// the same suite stands in for the process relaunching; the flag must
    /// still read granted.
    func testAlreadyGrantedPersistsAcrossLaunchesAndNeverReprompts() {
        EmailImportConsent.grant(defaults: defaults)
        let relaunchDefaults = UserDefaults(suiteName: "EmailImportConsentTests")!
        XCTAssertEqual(EmailImportConsent.fetchDecision(defaults: relaunchDefaults), .fetchImmediately)
    }

    /// Requirement: "Not now does not grant, and re-opening prompts again"
    /// — `ImportAddressCard`'s dialog has `Button("Not now", role: .cancel)
    /// {}`, an empty closure that never calls `grant()`, so declining leaves
    /// consent unrecorded: the card stays in `.needsConsent` and tapping
    /// "Show email address" again re-opens the same dialog rather than
    /// silently fetching.
    func testDecliningLeavesConsentUnrecordedSoCardStaysInNeedsConsent() {
        // No `grant()` call — mirrors "Not now"'s no-op action exactly.
        XCTAssertFalse(EmailImportConsent.isGranted(defaults: defaults))
        XCTAssertEqual(EmailImportConsent.fetchDecision(defaults: defaults), .needsConsent)
    }

    /// Requirement (design brief: "do NOT reuse the paste key — different
    /// disclosure scope"): the paste-import and email-import consent keys
    /// are independent — granting one must never grant the other.
    func testEmailConsentIsIndependentOfPasteImportConsent() {
        AIImportConsent.grant(defaults: defaults)
        XCTAssertTrue(AIImportConsent.isGranted(defaults: defaults))
        XCTAssertFalse(EmailImportConsent.isGranted(defaults: defaults))
        XCTAssertEqual(EmailImportConsent.fetchDecision(defaults: defaults), .needsConsent)
    }
}
