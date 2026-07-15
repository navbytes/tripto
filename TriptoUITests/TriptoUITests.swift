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

    // MARK: - Double-tap Save: exactly one item, not one per tap
    //
    // Fix-round D2: `AddItemSheet.save()` used to have no in-flight guard
    // between its synchronous SwiftData insert and the `dismiss()` call it
    // ends with — a fast double-tap could land both taps before the sheet's
    // dismiss animation removed the button from the hittable hierarchy, each
    // one independently passing `guard isValid` and inserting its own
    // `ItineraryItem` (confirmed live pre-fix: reproducibly created two
    // "ZZ..." flights from one double-tap). `save()` now guards on a
    // synchronous `isSaving` flag (same shape as `dismissSuggestion()`'s own
    // `isDismissingSuggestion`), which also disables both footer Save
    // buttons. This test used to wrap its final assertion in
    // `XCTExpectFailure` as a tripwire for that fix landing; now unwrapped —
    // it asserts the real, fixed behavior directly.

    /// `.doubleTap()` (one XCUITest call synthesizing two touches back to
    /// back) reproduces a real fast double-tap far more reliably than two
    /// separate `.tap()` calls, which XCUITest's own quiescence wait can
    /// serialize past whatever dismiss animation the first tap kicks off.
    func testDoubleTapSaveCreatesAtMostOneFlightItem() {
        let app = launch(["-uitestOpenAdd", "-uitestOpenBookings"])
        let fromField = app.textFields["e.g. JFK"]
        XCTAssertTrue(fromField.waitForExistence(timeout: 30), "Add-item sheet (flight) never appeared")
        fromField.tap()
        fromField.typeText("SFO")
        let toField = app.textFields["e.g. LIS"]
        toField.tap()
        toField.typeText("LAX")
        // Unique per run (same reasoning as `testPackingAddAndCheckOff`'s
        // UUID-suffixed label): the seeded trip persists across relaunches,
        // so a fixed flight number would collide with — and silently
        // accumulate on top of — whatever an earlier run of this exact test
        // already left behind. Feeds the transient title (and the
        // boarding-pass carrier line).
        let flightNo = "ZZ" + UUID().uuidString.prefix(8)
        let flightNoField = app.textFields["TP1234"]
        flightNoField.tap()
        flightNoField.typeText(flightNo)

        let saveButton = app.buttons["Add flight to itinerary"]
        XCTAssertTrue(saveButton.exists)
        saveButton.doubleTap()

        XCTAssertTrue(
            app.staticTexts["Lisbon"].waitForExistence(timeout: 10), "sheet didn't dismiss back to the trip"
        )

        // `BookingRow` is a `NavigationLink` (bridges to a `.button`-type
        // element outside a `List`) wrapping `.accessibilityElement(children:
        // .ignore)` + a combined label — VoiceOver hears one stop per row.
        // But `.ignore` only governs what VoiceOver announces; it does NOT
        // remove the row's inner `Text(item.title)` from XCUITest's own
        // element tree, so a broad `descendants(matching: .any)` query
        // double-counts a single real row: once for the row's own combined
        // `.button` element, again for that inner static text — both
        // independently contain the flight number substring. Scoping to
        // `.buttons` only (the row's own bridged type; a plain `Text` is
        // `.staticText`, never `.button`) counts real rows, not incidental
        // sub-elements. Flight is the first category group (`BookingsTabView
        // .groups` iterates `ItemCategory.allCases`) and this is the only
        // "current" (not "past") flight in the seed, so it's on-screen with
        // no scrolling.
        let matches = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", flightNo))
        XCTAssertGreaterThan(matches.count, 0, "the new flight never appeared on the Bookings tab")
        XCTAssertEqual(matches.count, 1, "double-tapping Save should create exactly one flight, not one per tap")
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

    // MARK: - Paste-to-import entry point (AddItemSheet, P3.5 + P4.2)
    //
    // Used to cover `ShareTripView`'s "Or paste text instead" button next to
    // its email-import address card. Phase 4 (docs/UX_REDESIGN_ROADMAP.md
    // P4.2) moved the whole "get data in" cluster (paste OR forward-by-
    // email) off Share entirely, onto the Add sheet's own `pasteFirstBanner`
    // (P3.5) — retargeted here rather than deleted, so this suite keeps a
    // second, deliberately-kept-separate entry point covered besides
    // `TripView.pasteImportPill` below. `pasteFirstBanner` matches by
    // `accessibilityIdentifier`, not visible text — `.accessibilityElement(
    // children: .combine)` concatenates its title/subtitle into one label.
    func testPasteImportEntryPointFromAddSheet() {
        let app = launch(["-uitestOpenAdd"])
        let pasteButton = app.buttons["pasteFirstBanner"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 30), "Add sheet's paste-banner entry point never appeared")
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

    // MARK: - P3 milestone screenshot (add-item sheet rework: verb tiles,
    // paste banner, live BoardingPassCard preview, seat/gate disclosure,
    // sticky footer + return leg) — same "config-agnostic test,
    // appearance/Dynamic Type flipped from OUTSIDE between separate
    // invocations" recipe as `testCaptureItineraryScreen` above (see the
    // Tester report for the exact `xcrun simctl ui` commands). The pass-face
    // assignee/pending parity half of this milestone needs no new capture
    // here — `testCaptureItineraryScreen` above already frames Day 1's
    // `TAP TP1234` card, which (`DemoSeeder.flights`, assigned to Grandma)
    // renders both an assignee avatar and — every seeded row stays queued
    // under this suite's standard `-simulateOffline` launch flag — the
    // pending pill with no seed changes needed.

    /// Fills the flight form with the same JFK/LIS/TAP1234/14C-1-22-QK7P2M
    /// values `DemoSeeder`'s own outbound flight and
    /// `AddItemSheetFlightDetailsSummaryTests` already use (so the
    /// screenshot's data reads as a consistent fixture, not arbitrary test
    /// filler) — enough for the live `BoardingPassCard` preview (P3.2) to
    /// render a real route/carrier instead of placeholder em-dashes — then
    /// expands the seat/terminal/gate/confirmation disclosure (P3.3), which
    /// is collapsed by default on a blank form.
    ///
    /// Captures at *two* natural scroll depths rather than forcing one:
    /// right after the route fields (where XCUITest's own auto-scroll-to-
    /// hittable hasn't moved the form far — the live pass preview is still
    /// in frame, `add-item-flight-preview`), and again after the
    /// disclosure's own fields (where, at accessibility Dynamic Type sizes,
    /// the same auto-scroll has naturally moved much further down —
    /// `add-item-flight-disclosure`, the always-sticky footer still in
    /// frame either way since it's a fixed sibling of the `ScrollView`, not
    /// part of its scrollable content). The default-size runs (light/dark)
    /// use the first; the accessibility-size run uses the second — see the
    /// Tester report for which attachment maps to which of the 3 requested
    /// PNGs.
    func testCaptureAddItemFlightSheet() {
        let app = launch(["-uitestOpenAdd"])
        let fromField = app.textFields["e.g. JFK"]
        XCTAssertTrue(fromField.waitForExistence(timeout: 30), "Add-item sheet (flight) never appeared")

        let airlineField = app.textFields["TAP Air Portugal"]
        airlineField.tap()
        airlineField.typeText("TAP Air Portugal")
        let flightNoField = app.textFields["TP1234"]
        flightNoField.tap()
        flightNoField.typeText("TP1234")
        fromField.tap()
        fromField.typeText("JFK")
        let toField = app.textFields["e.g. LIS"]
        toField.tap()
        toField.typeText("LIS")
        // Dismiss the keyboard *before* reaching for the next-day chip
        // below — while it's up, it covers roughly the bottom half of the
        // screen, and XCUITest's auto-scroll-to-hittable has to scroll
        // considerably further to bring an otherwise-nearby control into
        // the remaining, keyboard-free visible area.
        app.keyboards.buttons["return"].tap()

        // JFK's real zone (America/New_York, auto-detected from the code
        // just typed) sits ~5h behind the trip-default zone `departsTime`'s
        // clock value was originally set against, so — unadjusted — the
        // composed arrival instant now lands *before* departure (the
        // "+1 day" auto-suggest is wall-clock-only, doesn't know a zone
        // changed) and the form would show a red validation error instead
        // of a clean preview. Forcing "+1 day" (`arrivalDayOffsetOverride`)
        // is the same fix a real person filling this same route would
        // reach for.
        let nextDayChip = app.buttons["Arrives next day"]
        XCTAssertTrue(nextDayChip.waitForExistence(timeout: 5), "+1 day chip never appeared")
        nextDayChip.tap()
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "add-item-flight-preview", of: app)

        // P3.3: the label row is the `DisclosureGroup`'s own native tap
        // target — no custom `.disclosureGroupStyle` involved — matched by
        // its combined accessibility label (`disclosureLabel`'s
        // `.accessibilityElement(children: .combine)`) since the two
        // underlying `Text`s aren't independently queryable.
        let disclosure = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", "Seat, terminal, gate")).firstMatch
        XCTAssertTrue(disclosure.waitForExistence(timeout: 5), "seat/terminal/gate disclosure never appeared")
        disclosure.tap()

        let seatField = app.textFields["14C"]
        XCTAssertTrue(seatField.waitForExistence(timeout: 5), "disclosure didn't expand")
        seatField.tap()
        seatField.typeText("14C")
        let terminalField = app.textFields["1"]
        terminalField.tap()
        terminalField.typeText("1")
        let gateField = app.textFields["22"]
        gateField.tap()
        gateField.typeText("22")
        let confirmationField = app.textFields["QK7P2M"]
        confirmationField.tap()
        confirmationField.typeText("QK7P2M")
        // Dismiss the keyboard (the software Return key resigns first
        // responder on this single-line field, same as any plain
        // `TextField` with no `.onSubmit` override) — otherwise it covers
        // the lower half of the screenshot.
        app.keyboards.buttons["return"].tap()
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "add-item-flight-disclosure", of: app)
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
