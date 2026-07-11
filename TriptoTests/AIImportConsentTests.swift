import XCTest
@testable import Tripto

/// AI-import consent gate (Apple Guideline 5.1.2(i), rewritten 2025-11-13:
/// explicit permission before sharing user data with a third-party AI).
///
/// `PasteImportSheet.submit()` — the only call site that reaches the network
/// — is reachable from exactly two places in source: the Import button's
/// `.sendImmediately` branch, and the consent dialog's "Continue" button
/// (which calls `grant()` immediately before `submit()`). So exercising
/// `tapOutcome`/`grant`/`isGranted` here is a complete, network-free proof of
/// the gate decision (this milestone's brief: "structure the test around the
/// gate DECISION, not a live network call") — no UI test needed.
///
/// Same injectable-`UserDefaults` recipe as `PassEffectsTests`' torn-stub
/// suite, so this never touches the real `UserDefaults.standard`.
final class AIImportConsentTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "AIImportConsentTests")
        defaults.removePersistentDomain(forName: "AIImportConsentTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "AIImportConsentTests")
        defaults = nil
        super.tearDown()
    }

    func testNotGrantedByDefault() {
        XCTAssertFalse(AIImportConsent.isGranted(defaults: defaults))
    }

    /// Requirement: "not-granted ⇒ server not called until accept" — a
    /// first-ever tap must show the prompt, not send. `PasteImportSheet`'s
    /// Import button only reaches `submit()` on the `.sendImmediately` case.
    func testTapOutcomeShowsConsentPromptWhenNotGranted() {
        XCTAssertEqual(AIImportConsent.tapOutcome(defaults: defaults), .showConsentPrompt)
    }

    /// Requirement: "accept records consent + proceeds" — `grant()` flips
    /// the flag, and the next tap decision now sends immediately. The
    /// dialog's "Continue" button calls exactly `grant()` then `submit()`,
    /// in that order (see `PasteImportSheet.body`).
    func testGrantRecordsConsentAndTapOutcomeThenSendsImmediately() {
        AIImportConsent.grant(defaults: defaults)
        XCTAssertTrue(AIImportConsent.isGranted(defaults: defaults))
        XCTAssertEqual(AIImportConsent.tapOutcome(defaults: defaults), .sendImmediately)
    }

    /// Requirement: "already-granted ⇒ no re-prompt" — a second, independent
    /// `UserDefaults` instance backed by the same suite stands in for the
    /// process relaunching; the flag must still read granted.
    func testAlreadyGrantedPersistsAcrossLaunchesAndNeverReprompts() {
        AIImportConsent.grant(defaults: defaults)
        let relaunchDefaults = UserDefaults(suiteName: "AIImportConsentTests")!
        XCTAssertEqual(AIImportConsent.tapOutcome(defaults: relaunchDefaults), .sendImmediately)
    }

    /// Requirement: "cancel does not send" — the dialog's "Not now" button
    /// has an empty action closure (never calls `grant()`), so declining
    /// leaves consent unrecorded and a later tap still shows the prompt
    /// again rather than silently proceeding.
    func testDecliningLeavesConsentUnrecordedSoPromptShowsAgain() {
        // No `grant()` call — mirrors "Not now"'s no-op action exactly.
        XCTAssertFalse(AIImportConsent.isGranted(defaults: defaults))
        XCTAssertEqual(AIImportConsent.tapOutcome(defaults: defaults), .showConsentPrompt)
    }
}
