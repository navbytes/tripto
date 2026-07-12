import XCTest
@testable import Tripto

/// User-selectable import processing mode (PLAN.md Addendum: "users must be
/// able to CHOOSE cloud LLM") — mirrors `AIImportConsentTests` exactly in
/// shape (see `ImportProcessingMode`'s doc comment, `PasteImportSheet.swift`,
/// for why this is a two-case preference rather than a third "never cloud"
/// mode: that's already `AIImportConsent`'s job).
///
/// Same injectable-`UserDefaults` recipe as `AIImportConsentTests`/
/// `EmailImportConsentTests`, so this never touches the real
/// `UserDefaults.standard`.
final class ImportProcessingModeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ImportProcessingModeTests")
        defaults.removePersistentDomain(forName: "ImportProcessingModeTests")
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "ImportProcessingModeTests")
        defaults = nil
        super.tearDown()
    }

    /// PLAN.md Addendum: "default onDevice."
    func testDefaultsToOnDeviceWhenNothingStored() {
        XCTAssertEqual(ImportProcessingMode.current(defaults: defaults), .onDevice)
    }

    func testSetPersistsAndReadsBack() {
        ImportProcessingMode.set(.cloud, defaults: defaults)
        XCTAssertEqual(ImportProcessingMode.current(defaults: defaults), .cloud)
    }

    /// Mirrors `AIImportConsentTests
    /// .testAlreadyGrantedPersistsAcrossLaunchesAndNeverReprompts`: a
    /// second, independent `UserDefaults` instance backed by the same suite
    /// stands in for the process relaunching.
    func testChoicePersistsAcrossLaunches() {
        ImportProcessingMode.set(.cloud, defaults: defaults)
        let relaunchDefaults = UserDefaults(suiteName: "ImportProcessingModeTests")!
        XCTAssertEqual(ImportProcessingMode.current(defaults: relaunchDefaults), .cloud)
    }

    /// Switching back to `.onDevice` after `.cloud` overwrites cleanly, not
    /// additively — a plain `UserDefaults.set` under one key, no merge
    /// logic to regress.
    func testSwitchingBackToOnDeviceOverwritesPriorChoice() {
        ImportProcessingMode.set(.cloud, defaults: defaults)
        ImportProcessingMode.set(.onDevice, defaults: defaults)
        XCTAssertEqual(ImportProcessingMode.current(defaults: defaults), .onDevice)
    }

    /// A garbage/legacy string under the key (e.g. a future-removed case,
    /// or a value written by a newer app version this build doesn't know
    /// about) must fall back to the documented default, not crash or read
    /// as `.cloud`. Uses the literal key PLAN.md Addendum specifies
    /// ("importProcessingMode") since `ImportProcessingMode.key` is
    /// private — this is deliberately exercising the storage FORMAT, not
    /// just the type's own accessors.
    func testUnrecognizedStoredValueFallsBackToOnDeviceDefault() {
        defaults.set("legacyModeThatNoLongerExists", forKey: "importProcessingMode")
        XCTAssertEqual(ImportProcessingMode.current(defaults: defaults), .onDevice)
    }
}
