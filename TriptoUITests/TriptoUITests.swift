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
        let fab = app.buttons["Add packing items"]
        XCTAssertTrue(fab.waitForExistence(timeout: 30), "Packing tab / FAB never appeared")
        fab.tap()

        let addItem = app.buttons["Add item"]
        XCTAssertTrue(addItem.waitForExistence(timeout: 5), "FAB confirmation dialog didn't show 'Add item'")
        addItem.tap()

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
        XCTAssertTrue(row.waitForExistence(timeout: 10), "new packing item row didn't appear in the list")
        XCTAssertEqual(row.value as? String, "Not packed", "new item should start unpacked")
        row.tap()
        XCTAssertEqual(row.value as? String, "Packed", "tapping the row should check it off")
    }

    // MARK: - Paste-to-import entry point (ShareTripView)
    //
    // A second entry point beside the one below: `ShareTripView`'s "Or
    // paste text instead" button next to the email-import address card,
    // reachable on the already-seeded (non-empty) demo trip via
    // `-uitestOpenShare`.
    func testPasteImportEntryPointFromShare() {
        let app = launch(["-uitestOpenShare"])
        let pasteButton = app.buttons["Or paste text instead"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 30), "Share screen / paste entry point never appeared")
        pasteButton.tap()

        XCTAssertTrue(
            app.staticTexts["Paste a booking"].waitForExistence(timeout: 5),
            "PasteImportSheet did not present with the booking title"
        )
    }

    // MARK: - Paste-to-import entry point (AddItemSheet's dashed tile)
    //
    // The 6th "Paste" tile in `AddItemSheet`'s category row
    // (`addItemCategoryTile-paste`). Tapping it dismisses `AddItemSheet`
    // and, via `TripView`'s `onDismiss` handoff (`pasteRequestedFromAdd`),
    // presents `PasteImportSheet(kind: .booking, ...)` — this is the
    // click-through that was never actually driven end-to-end before this
    // test existed (only visually confirmed via screenshot that the tile
    // rendered).
    func testAddItemSheetPasteTile() {
        let app = launch(["-uitestOpenAdd"])
        let pasteTile = app.buttons["addItemCategoryTile-paste"]
        XCTAssertTrue(pasteTile.waitForExistence(timeout: 30), "Add-item sheet's Paste tile never appeared")
        pasteTile.tap()

        XCTAssertTrue(
            app.staticTexts["Paste a booking"].waitForExistence(timeout: 5),
            "Tapping the Paste tile did not hand off to PasteImportSheet"
        )
    }
}
