import XCTest

/// First XCUITest coverage for Tripto — smoke pass driven through the
/// `-uitestXxx` launch-argument hooks already baked into the app
/// (`App/*View.swift`, `Support/DemoSeeder.swift`) rather than raw taps
/// through Sign in with Apple, which XCUITest can't drive at all.
///
/// `-uitestAutoSignIn` injects a fixed fake session directly in
/// `AuthManager.init` (`#if DEBUG`, BACKLOG.md C4) — no network call, no
/// Keychain, no dependency on the backend's anonymous-sign-in setting
/// (disabled in production). `-simulateOffline` is added to every launch on
/// top of that so `DemoSeeder`'s seed data (and every add/edit this suite
/// performs) stays queued in the local outbox instead of attempting a push
/// — together the two flags make this suite's every launch fully hermetic.
final class TriptoUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Launches with the sign-in + seed + open-first-trip combo every test
    /// below builds on. `-uitestAutoSignIn`'s fixed user id means every
    /// launch is the same identity, so `DemoSeeder`'s "Lisbon" seed (keyed
    /// off `HomeView`'s `trips.isEmpty` check) and anything this suite adds
    /// persist consistently across every launch within a run. This used to
    /// need a disposable `-uitestSignOut` pre-launch to dodge a stale
    /// *real* anonymous identity surviving in the Keychain across app
    /// reinstall on the Simulator (a known simulator quirk) — moot now that
    /// this path never touches the SDK's session/Keychain at all.
    private func launch(_ extraArgs: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestOpenFirstTrip"
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

    // MARK: - P1+P2 milestone screenshots (docs/UX_REDESIGN_ROADMAP.md Phase
    // 2's own "Verify wave: tester, reviewer, ux-expert (timeline milestone:
    // P1+P2 screenshots)") — light/dark appearance and Dynamic Type size are
    // simulator-level settings this test can't flip mid-run, so they're
    // driven from OUTSIDE (`xcrun simctl ui <device> appearance|content_size`
    // against the same booted device, host-side, between three separate
    // invocations of `testCaptureItineraryScreen` — see the Tester report
    // for the exact commands). Each method here is config-agnostic: it just
    // navigates and attaches a full-screen `XCTAttachment`, whatever the
    // device's current appearance/type size happens to be.

    func testCaptureHomeScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Lisbon"].waitForExistence(timeout: 30), "Home never showed the seeded trip")
        attachScreenshot(named: "home", of: app)
    }

    /// `.itinerary` is `TripView`'s own default tab (`selectedTab: Tab =
    /// .itinerary`), so no extra tap is needed once the trip opens. The
    /// seeded trip (as of this milestone) carries a tz-crossing flight with
    /// its landing note, an overlapping hotel pair (`DemoSeeder`'s
    /// `hotel1`/`hotel1Duplicate`) so the conflict banner + per-card flag
    /// both render, and several multi-night stay strips.
    func testCaptureItineraryScreen() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Lisbon"].waitForExistence(timeout: 30), "trip never opened")
        // Let the hero's one-shot layout measurement + the conflict/today
        // auto-scroll `.task` settle before capturing.
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(named: "itinerary", of: app)
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
