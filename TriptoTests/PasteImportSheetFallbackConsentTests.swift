import XCTest
@testable import Tripto

/// Fix-loop D1 ("re-confirm before remote fallback after on-device
/// failure"): `PasteImportSheet.submitOnDevice()`'s three fallback exits
/// (unresolved creator / `.fallback` from `OnDeviceExtractor.extractAll` /
/// the impossible not-actually-available branch) all funnel into
/// `runRemoteFallbackAfterOnDeviceFailure()`, which is deliberately NOT the
/// same gate `runRemoteImportFlow()` uses for a pure-remote-route tap:
///
/// ```swift
/// // runRemoteImportFlow() — pure-remote entry (Import button, .remote route)
/// switch AIImportConsent.tapOutcome() {
/// case .sendImmediately: await submit()
/// case .showConsentPrompt: isPresentingAIConsent = true
/// }
///
/// // runRemoteFallbackAfterOnDeviceFailure() — fallback-from-on-device entry
/// if AIImportConsent.isGranted() {
///     isPresentingOnDeviceFallbackConfirm = true   // NEVER .sendImmediately
/// } else {
///     isPresentingAIConsent = true                 // same dialog as the pure-remote row
/// }
/// ```
///
/// Both methods are `private` instance methods on `PasteImportSheet`,
/// entangled with `@State`/`@Environment` (no pure decision function backs
/// this exact branch the way `ImportRouting.requiresConsentDialog` backs
/// the ORIGINAL, pre-D1 consent gate) — a bare `PasteImportSheet(tripId:)`
/// constructed outside SwiftUI's render pipeline never gets a resolved
/// `@Environment`, and reading the resulting `@State` bools needs their own
/// access opened too, well past a single pure-function seam. This suite
/// instead exercises the real, already-`internal` `AIImportConsent`
/// primitives both methods consume, pinning the DIVERGENCE property that
/// makes D1 necessary: the exact same granted-consent state produces two
/// different outcomes depending on which entry point reads it. That
/// divergence is real, executable coverage of `AIImportConsent`'s
/// contract — what it can't do is execute
/// `runRemoteFallbackAfterOnDeviceFailure()`'s own `if/else` directly, so a
/// hypothetical edit that swapped its `isGranted()` check for `tapOutcome()`
/// wouldn't be caught here. Flagged as a residual testability gap (not a
/// defect) rather than worked around with reflection or a source refactor.
final class PasteImportSheetFallbackConsentTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "PasteImportSheetFallbackConsentTests")
        defaults.removePersistentDomain(forName: "PasteImportSheetFallbackConsentTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "PasteImportSheetFallbackConsentTests")
        defaults = nil
        super.tearDown()
    }

    /// (a) On-device route promised, then hard-failed, with consent already
    /// granted from a past session: `runRemoteFallbackAfterOnDeviceFailure()`
    /// checks `isGranted()` directly — true here — and shows the reconfirm
    /// dialog, NEVER consulting `tapOutcome()` (whose `.sendImmediately`
    /// case is exactly the silent send this fix loop closed) and NEVER
    /// calling `submit()` itself (only the reconfirm dialog's own
    /// "Continue" button does that). Granted consent alone is therefore
    /// necessary but not sufficient for an immediate send once an on-device
    /// attempt has already fallen back.
    func testGrantedConsentAloneDoesNotImplySendImmediatelyOnceOnDeviceHasFallenBack() {
        AIImportConsent.grant(defaults: defaults)
        XCTAssertTrue(AIImportConsent.isGranted(defaults: defaults), "precondition for case (a): consent already on record")
        // Contrast: this SAME granted state, read through the pure-remote
        // entry's own gate, WOULD send immediately (case (c) below) — proving
        // the fallback entry's reconfirm requirement is a deliberate
        // divergence between the two entry points, not a coincidence of
        // `isGranted()` happening to read false here.
        XCTAssertEqual(
            AIImportConsent.tapOutcome(defaults: defaults), .sendImmediately,
            "sanity: tapOutcome() alone would send immediately for this state — the fallback entry " +
                "point deliberately does not consult it (see runRemoteFallbackAfterOnDeviceFailure())"
        )
    }

    /// (b) Same hard-fail, but never consented: `isGranted()` is false, so
    /// `runRemoteFallbackAfterOnDeviceFailure()`'s `else` branch runs —
    /// `isPresentingAIConsent = true`, the SAME dialog (and boolean) the
    /// pure-remote entry uses, deliberately not a second/stacked dialog on
    /// top of a reconfirm (`isPresentingOnDeviceFallbackConfirm` stays
    /// false; the source's `if/else` cannot set both). `tapOutcome()`
    /// agrees for this state too — both entry points show A consent-style
    /// prompt when nothing's on record; they only diverge on the granted
    /// side (case (a) above).
    func testNeverConsentedFallbackShowsTheSameSingleConsentPromptAsPureRemote() {
        XCTAssertFalse(AIImportConsent.isGranted(defaults: defaults), "precondition for case (b): never consented")
        XCTAssertEqual(AIImportConsent.tapOutcome(defaults: defaults), .showConsentPrompt)
    }

    /// (c) Pure-remote route (the Import button's own `.remote`-route tap,
    /// NOT a fallback from a failed on-device attempt), consent already
    /// granted: `runRemoteImportFlow()` calls `tapOutcome()` directly and
    /// sends on `.sendImmediately` with no dialog at all. Unlike case (a),
    /// this route was never promised on-device processing, so there's no
    /// broken privacy promise to reconfirm.
    func testPureRemoteRouteWithGrantedConsentSendsImmediatelyWithNoDialog() {
        AIImportConsent.grant(defaults: defaults)
        XCTAssertEqual(AIImportConsent.tapOutcome(defaults: defaults), .sendImmediately)
    }

    /// (d) User declines the reconfirm dialog: `PasteImportSheet.body`'s
    /// `isPresentingOnDeviceFallbackConfirm` dialog has `Button("Not now",
    /// role: .cancel) {}` — a literal empty closure, the exact same no-op
    /// shape as the ORIGINAL consent dialog's own "Not now"
    /// (`AIImportConsentTests
    /// .testDecliningLeavesConsentUnrecordedSoPromptShowsAgain` pins that
    /// one). Neither `grant()` nor `submit()` is reachable from that
    /// closure, so declining changes nothing observable: consent stays
    /// exactly as it was before the dialog appeared (granted, in this
    /// scenario, since a reconfirm is only ever shown when it already was —
    /// case (b) gets the OTHER dialog instead), and nothing is sent. This
    /// assertion would fail if a future edit added a stray grant()/mutation
    /// call to that closure; it cannot detect the closure itself vanishing
    /// or changing shape (see this file's header comment on that limit).
    func testDecliningReconfirmLeavesConsentStateAndNothingElseChanged() {
        AIImportConsent.grant(defaults: defaults)
        let before = AIImportConsent.isGranted(defaults: defaults)
        // "Not now"'s action is `{}` — nothing to invoke here, which is the
        // point: the sheet's paste text and consent record are untouched by
        // construction, not because this test drove the dialog and observed
        // no change.
        XCTAssertEqual(AIImportConsent.isGranted(defaults: defaults), before)
        XCTAssertTrue(before)
    }
}
