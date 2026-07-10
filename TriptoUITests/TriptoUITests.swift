import XCTest

/// First XCUITest coverage for Tripto — smoke pass driven through the
/// `-uitestXxx` launch-argument hooks already baked into the app
/// (`App/*View.swift`, `Support/DemoSeeder.swift`) rather than raw taps
/// through Sign in with Apple, which XCUITest can't drive at all.
///
/// `-uitestAutoSignIn` calls the real `Supa.client.auth.signInAnonymously()`
/// (a live network call — this is the app's own sanctioned DEBUG-only test
/// path, not something invented for this suite; see `WelcomeView.swift`).
/// `-simulateOffline` is added to every launch so `DemoSeeder`'s seed data
/// (and every add/edit this suite performs) stays queued in the local
/// outbox instead of pushing to the real backend — the only live call this
/// suite makes is that one anonymous sign-in.
///
/// Requires a SIGNED build (`DEVELOPMENT_TEAM`/`CODE_SIGN_STYLE: Automatic`,
/// not `CODE_SIGNING_ALLOWED=NO`) — an unsigned build has no Keychain, so
/// the anonymous session never persists and `authManager.userId` stays nil,
/// which makes `DemoSeeder.seed` silently no-op. (Same gotcha as
/// `TriptoTests/LiveAuthWriteTests`.)
final class TriptoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches with the sign-in + seed + open-first-trip combo every test
    /// below builds on.
    ///
    /// Bug fix: the anonymous Supabase session persists in the Keychain
    /// across app uninstall/reinstall on the iOS *Simulator* specifically
    /// (a known simulator quirk — Keychain items survive app deletion
    /// there, unlike on a real device). A prior run's signed-in identity —
    /// or even a completely unrelated test's, e.g.
    /// `TriptoTests/LiveAuthWriteTests`, if it ever ran against this same
    /// simulator — leaks into this suite: `-uitestSeedIfEmpty` sees a
    /// non-empty `trips` (pulled down for that stale identity) and skips
    /// seeding, and `-uitestOpenFirstTrip` opens whatever trip already
    /// existed instead of the expected "Lisbon" seed (confirmed via an
    /// `app.debugDescription` dump on failure: a leftover "InviteClaimTest"
    /// trip). `-uitestSignOut` in a disposable throwaway launch first
    /// forces a genuinely fresh anonymous identity for the real launch
    /// below, every time — this is what actually fixes it; reinstalling
    /// the app alone (tried first) did not.
    private func launch(_ extraArgs: [String] = []) -> XCUIApplication {
        let signOutApp = XCUIApplication()
        signOutApp.launchArguments = ["-uitestSignOut"]
        signOutApp.launch()
        signOutApp.terminate()

        let app = XCUIApplication()
        app.launchArguments = [
            "-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestOpenFirstTrip",
        ] + extraArgs
        app.launch()
        return app
    }

    // MARK: - Smoke: sign-in + seed + tabs render

    func testSeededTripOpensAndTabsRender() {
        let app = launch()
        XCTAssertTrue(
            app.staticTexts["Lisbon"].waitForExistence(timeout: 30),
            "seeded trip hero title never appeared — sign-in/seed/navigate autopilot didn't complete"
        )

        for tab in ["Bookings", "Packing", "Itinerary"] {
            let button = app.buttons[tab]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "\(tab) tab button missing")
            button.tap()
            XCTAssertEqual(app.state, .runningForeground, "app left the foreground switching to \(tab)")
        }
    }

    // MARK: - Add item: Flight (default category)

    func testAddFlightItem() {
        let app = launch(["-uitestOpenAdd"])
        let fromField = app.textFields["e.g. JFK"]
        XCTAssertTrue(fromField.waitForExistence(timeout: 30), "Add-item sheet (flight) never appeared")
        fromField.tap()
        fromField.typeText("SFO")

        let toField = app.textFields["e.g. LIS"]
        toField.tap()
        toField.typeText("LAX")

        let saveButton = app.buttons["Add flight to itinerary"]
        XCTAssertTrue(saveButton.exists)
        saveButton.tap()

        XCTAssertTrue(
            app.staticTexts["Lisbon"].waitForExistence(timeout: 10), "sheet didn't dismiss back to the trip"
        )
    }

    // MARK: - Add item: Activity (category switch)

    func testAddActivityItem() {
        let app = launch(["-uitestOpenAdd"])
        let activityTile = app.buttons["addItemCategoryTile-activity"]
        XCTAssertTrue(activityTile.waitForExistence(timeout: 30), "Add-item sheet never appeared")
        activityTile.tap()

        let titleField = app.textFields["Belém Tower"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 5), "activity title field never appeared after switching category")
        titleField.tap()
        titleField.typeText("UI Test Activity")

        let saveButton = app.buttons["Add activity to itinerary"]
        XCTAssertTrue(saveButton.exists)
        saveButton.tap()

        XCTAssertTrue(app.staticTexts["Lisbon"].waitForExistence(timeout: 10))
    }

    // MARK: - Packing: add an item, then check it off

    func testPackingAddAndCheckOff() {
        let app = launch(["-uitestOpenPacking"])
        // TI-3: the FAB opens the add-item form directly again — its old
        // confirmation-dialog choice ("Add item" vs "Paste a list") lost
        // its second option to `TripView.pasteImportPill`, and a
        // one-item menu isn't a menu, so the dialog was removed too.
        let fab = app.buttons["Add a packing item"]
        XCTAssertTrue(fab.waitForExistence(timeout: 30), "Packing tab / FAB never appeared")
        fab.tap()

        let itemField = app.textFields["Passports, car seat, chargers\u{2026}"]
        XCTAssertTrue(itemField.waitForExistence(timeout: 5), "packing item form never appeared")
        itemField.tap()
        // Unique per run: the seeded trip/packing state persists across
        // relaunches (by app design — `HomeView`'s seed hook only runs
        // `if trips.isEmpty`), so a fixed label would collide with a row
        // left over from an earlier run of this same test and produce an
        // ambiguous "Multiple matching elements" lookup.
        let label = "UITest Sunglasses \(UUID().uuidString.prefix(8))"
        itemField.typeText(label)

        app.buttons["Add to packing list"].tap()

        let row = app.buttons[label]
        // D2 defect 6 root cause (verified via the failing run's captured
        // accessibility-hierarchy attachment, not assumed): the row *was*
        // being added every time — the header right above it read "5 of
        // 13 packed" (was 12) — so this was never an accessibility
        // regression in `PackingRow` (still a real `Button`, still
        // `.accessibilityLabel(item.label)` / `.accessibilityValue(
        // "Packed"/"Not packed")`, exactly what this test already
        // expects). The new item lands in the "Shared" group
        // (`PackingItemFormSheet`'s default `groupKey`), which
        // `PackingProgress.order` sorts *after* the seeded Documents/Kids
        // groups — a couple of screens' worth of rows down. SwiftUI's
        // `LazyVStack` (`PackingListView.list`) never instantiates a row
        // that far outside the rendered range, let alone renders it, so a
        // bare `waitForExistence` here could never see it — no amount of
        // waiting scrolls the list. Scrolling first (bounded, so a
        // genuine regression still fails fast rather than hanging) fixes
        // the test without touching the row's (correct) semantics.
        for _ in 0..<15 where !row.exists {
            app.swipeUp()
        }
        XCTAssertTrue(row.waitForExistence(timeout: 10), "new packing item row didn't appear in the list")
        XCTAssertEqual(row.value as? String, "Not packed", "new item should start unpacked")
        row.tap()
        XCTAssertEqual(row.value as? String, "Packed", "tapping the row should check it off")
    }

    // MARK: - Paste-to-import entry point (ShareTripView)
    //
    // A second, deliberately-kept-separate entry point beside
    // `TripView.pasteImportPill` below: `ShareTripView`'s "Or paste text
    // instead" button next to the email-import address card. Not one of
    // the three tabs the TI-3 consistency pass targeted (Share is its own
    // screen), so it kept its own trigger — reachable on the
    // already-seeded (non-empty) demo trip via `-uitestOpenShare`.
    func testPasteImportEntryPointFromShare() {
        let app = launch(["-uitestOpenShare"])
        let pasteButton = app.buttons["Or paste text instead"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 30), "Share screen / paste entry point never appeared")
        pasteButton.tap()

        XCTAssertTrue(
            app.staticTexts["Paste to import"].waitForExistence(timeout: 5),
            "PasteImportSheet did not present"
        )
    }

    // MARK: - Paste-to-import entry point (the shared pill, TI-3)
    //
    // TI-3: one consistent "Paste to import" pill (`pasteImportPill`,
    // `TripView.swift`), rendered once in the trip screen's shared chrome
    // so it's the same trigger/label/placement regardless of which of the
    // three tabs (Itinerary/Bookings/Packing) is selected — replaces four
    // previously-inconsistent doors a UX audit found (a disguised tile in
    // `AddItemSheet`'s category row, an empty-state-only link on
    // Itinerary, a confirmation-dialog item on Packing's FAB, and no
    // affordance at all on Bookings). This test exercises it from the
    // default (Itinerary) tab; the same identifier is reachable from
    // Bookings and Packing too since it's the same view instance.
    func testPasteImportPillOpensSheet() {
        let app = launch()
        let pasteButton = app.buttons["pasteImportPill"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 30), "Shared paste-import pill never appeared")
        pasteButton.tap()

        XCTAssertTrue(
            app.staticTexts["Paste to import"].waitForExistence(timeout: 5),
            "Tapping the pill did not present PasteImportSheet"
        )
    }
}
