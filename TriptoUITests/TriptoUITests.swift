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
        // Waits for the hero's one-shot layout measurement to actually
        // resolve (Lisbon's fixed May-2026 dates are behind "today," so the
        // conflict/today auto-scroll `.task` never fires for this trip — see
        // `testCaptureItineraryConflictBanner`'s own doc comment below)
        // rather than guessing a fixed settle duration.
        XCTAssertTrue(waitHittable(app.staticTexts["Lisbon"]), "hero title never became hittable — layout never settled")
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
        // Dismiss the keyboard *before* reaching for the date pickers below
        // — while it's up, it covers roughly the bottom half of the screen,
        // and XCUITest's auto-scroll-to-hittable has to scroll considerably
        // further to bring an otherwise-nearby control into the remaining,
        // keyboard-free visible area.
        app.keyboards.buttons["return"].tap()

        // `departsTime` defaults to the device's current wall clock — pinning
        // it to a fixed morning value keeps this capture's boarding-pass
        // screenshot deterministic regardless of when the suite actually
        // runs, rather than showing whatever real time this happened to be.
        let departsTimePicker = app.datePickers["Departs"].buttons["Time Picker"]
        XCTAssertTrue(departsTimePicker.waitForExistence(timeout: 5), "Departs time picker never appeared")
        departsTimePicker.tap()
        let hourWheel = app.pickerWheels.element(boundBy: 0)
        XCTAssertTrue(hourWheel.waitForExistence(timeout: 5), "Departs time picker wheels never appeared")
        hourWheel.adjust(toPickerWheelValue: "9")
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "00")
        app.pickerWheels.element(boundBy: 2).adjust(toPickerWheelValue: "AM")
        // Not `app.buttons["dismiss popup"]`: that "PopoverDismissRegion"
        // covers the whole screen MINUS the popover itself, an irregular
        // area whose XCUITest-computed tap point isn't something this test
        // controls — confirmed empirically at AX3, where it landed on the
        // "Departure time zone" row instead and opened ITS OWN zone-search
        // sheet (the resulting screenshot, from a real run, showed a "Time
        // zone" city list, not the flight preview). The sheet's own title
        // is a stable, always-present, non-interactive tap target well
        // outside the popover at any Dynamic Type size.
        app.staticTexts["Add to Lisbon"].tap()

        // P7 re-audit (round 2): the fix this scene now proves — route/
        // airline/departure are all filled but `arrivesTime` is still `nil`
        // (`hasSetArrival == false`), so the boarding-pass preview above
        // must render route-only (no duration/day badge), not a fabricated
        // arrival. Captured BEFORE the "Arrival date"/"Arrives" pickers
        // below are touched, which is what would flip `hasSetArrival` true.
        // Waits for the Departs popover's own wheel to actually leave the
        // hierarchy (dismissed) rather than guessing its close-animation
        // duration.
        XCTAssertTrue(waitGone(hourWheel), "Departs time popover never dismissed")
        attachScreenshot(named: "add-item-flight-preview-route-only", of: app)

        // P7c: the old boolean "+1 day" chip is gone — arrival is now an
        // explicit "Arrival date" picker plus its own "Arrives" time, and
        // the preview stays route-only (no duration/day badge) until a real
        // arrival is set (`AddItemSheet.hasSetArrival`). "Arrival date"
        // defaults to departure's own day, which is left as-is here — an
        // evening Lisbon arrival is a same-day, unambiguous, deterministic
        // instant regardless of the ~4-5h JFK/LIS zone gap (which shifts by
        // a rare DST-mismatch week either way), so there's no need to drive
        // its calendar-grid popover (whose day-cell labels aren't a stable,
        // locale-independent target the way a wheel-adjust is). Same
        // wheel-adjust recipe as "Departs" above — this is the write that
        // actually flips `arrivesTime` from `nil` to a real value
        // (`hasSetArrival`), which is what takes the preview out of
        // route-only and renders a real duration, matching this capture's
        // original (pre-P7c) intent.
        //
        // P7e (round-2 re-audit item 1): "Arrival date"/"Arrives" render as
        // an unset placeholder pair (`arrivalDatePlaceholder`/
        // `arrivesTimePlaceholder`) until this first tap — matched by their
        // own stable identifiers rather than visible text, same reasoning
        // `pasteFirstBanner`'s doc comment already gives. This is the tap
        // that reveals the real pickers below (both together — one shared
        // `hasSetArrival`), so `datePickers["Arrives"]` only exists after it.
        let arrivesTimePlaceholder = app.buttons["arrivesTimePlaceholder"]
        XCTAssertTrue(arrivesTimePlaceholder.waitForExistence(timeout: 5), "Arrives placeholder never appeared")
        arrivesTimePlaceholder.tap()

        let arrivesTimePicker = app.datePickers["Arrives"].buttons["Time Picker"]
        XCTAssertTrue(arrivesTimePicker.waitForExistence(timeout: 5), "Arrives time picker never appeared")
        arrivesTimePicker.tap()
        let arrivesHourWheel = app.pickerWheels.element(boundBy: 0)
        XCTAssertTrue(arrivesHourWheel.waitForExistence(timeout: 5), "Arrives time picker wheels never appeared")
        arrivesHourWheel.adjust(toPickerWheelValue: "9")
        app.pickerWheels.element(boundBy: 1).adjust(toPickerWheelValue: "00")
        app.pickerWheels.element(boundBy: 2).adjust(toPickerWheelValue: "PM")
        // Same dismiss target as Departs' popover above.
        app.staticTexts["Add to Lisbon"].tap()

        XCTAssertTrue(waitGone(arrivesHourWheel), "Arrives time popover never dismissed")
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
        XCTAssertTrue(waitGone(app.keyboards.buttons["return"]), "keyboard never dismissed")
        attachScreenshot(named: "add-item-flight-disclosure", of: app)
    }

    // MARK: - Double-tap "Start from a booking email instead": exactly one
    // trip, not one per tap
    //
    // P4.4 hardening: unlike `AddItemSheet.save()` (fix-round D2, see
    // `testDoubleTapSaveCreatesAtMostOneFlightItem` above), `TripFormView
    // .save()`'s create branch has no `isSaving`-style reentrancy guard —
    // `canSubmit`/`.disabled(!canSubmit)` only reflects whether the form
    // *fields* are valid, not whether a save is already mid-flight, so
    // nothing here stops a second synchronous `save()` between the first
    // tap's SwiftData insert and the sheet-chain transition that eventually
    // makes the button unhittable. This pins the desired behavior — a real
    // regression to fix in `TripFormView.save()`, not this test, if it fails.

    func testDoubleTapStartFromBookingEmailCreatesExactlyOneTrip() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty"]
        app.launch()
        // Not `app.staticTexts["Lisbon"]`: this repo's local store persists
        // across launches (`-simulateOffline`), so a previous run of this
        // very test can leave other trips behind, and the seeded (Past-dated)
        // Lisbon trip isn't guaranteed to be the first row. "Your trips" is
        // `header`'s fixed chrome above the one list (docs/UX_REDESIGN_ROADMAP.md
        // Phase 5 retired the Upcoming/Past `SegmentedControl` this used to
        // wait on) — unlike `planNewTripRow`, the list's own last row (pushed
        // off-screen, and so not yet instantiated by SwiftUI's lazy `List`,
        // once enough trips accumulate across repeated local runs), it
        // renders regardless of scroll position or list contents.
        XCTAssertTrue(app.staticTexts["Your trips"].waitForExistence(timeout: 30), "Home never loaded")

        // `planNewTripRow` is the list's own last row — scroll to it rather
        // than assume it's already on-screen, same bounded-swipe technique
        // `testPackingAddAndCheckOff` uses for the same reason.
        let planNewTripButton = app.buttons["Plan a new trip"]
        for _ in 0..<15 where !planNewTripButton.exists {
            app.swipeUp()
        }
        XCTAssertTrue(planNewTripButton.waitForExistence(timeout: 10), "'Plan a new trip' row never scrolled into view")
        planNewTripButton.tap()
        let titleField = app.textFields["Lisbon"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "New-trip sheet never appeared")
        titleField.tap()
        // Unique per run — same reasoning as `testDoubleTapSaveCreatesAtMostOneFlightItem`'s
        // `flightNo`/`testPackingAddAndCheckOff`'s `label`.
        let uniqueTitle = "ZZ Booking Chain " + UUID().uuidString.prefix(8)
        titleField.typeText(uniqueTitle)
        // `tripNameField`'s `.submitLabel(.done)` (unlike `AddItemSheet`'s
        // plain-return fields the other double-tap test above dismisses)
        // renders a "Done" key, not "return".
        app.keyboards.buttons["Done"].tap()

        let bookingEmailButton = app.buttons["Start from a booking email instead"]
        XCTAssertTrue(bookingEmailButton.exists)
        bookingEmailButton.doubleTap()

        // Whatever got created is already durably saved to the local
        // SwiftData store the instant each `save()` call runs (synchronous,
        // before any sheet transition) — terminating and relaunching reads
        // back that same on-disk state without needing to navigate out of
        // however many chained sheets the (possibly doubled) saves left
        // presented, and sidesteps `TripFormView` and `AddItemSheet` both
        // rendering their own same-labeled "Cancel" `SheetHeader` button
        // simultaneously in the accessibility tree (ambiguous to query).
        let pasteBanner = app.buttons["pasteFirstBanner"]
        XCTAssertTrue(pasteBanner.waitForExistence(timeout: 10), "chained AddItemSheet never appeared")
        // This machine's `xcodebuild test` runs have shown general
        // launch/relaunch slowness independent of this test (matches the P4
        // handoff's own noted pre-existing flakiness) — see `relaunch(_:)`'s
        // own doc comment for why its settle sleep is kept.
        relaunch(app)
        // Same fixed-chrome reasoning as the first wait above (not
        // `Plan a new trip`/`Lisbon`) — a generous 60s timeout for the same
        // reason as the settle sleep above.
        XCTAssertTrue(app.staticTexts["Your trips"].waitForExistence(timeout: 60), "Home never reappeared after relaunch")
        // docs/UX_REDESIGN_ROADMAP.md Phase 5: no tab to select any more —
        // the newly created trip(s), dated today, are always in the one list.

        // `TripCard` is `.accessibilityElement(children: .ignore)` with one
        // combined label starting with the title (`HomeView.swift`'s
        // `tripList`, `TripCard.accessibilityLabel`) — same CONTAINS-on-
        // `.buttons` technique as the flight double-tap test above, for the
        // same reason (the card is wrapped in a `Button`, not independently
        // queryable as a `.staticText`). Scrolled for, same reason as
        // `planNewTripButton` above: repeated local runs of this same test
        // accumulate trips in the (cross-launch-persistent) local store, and
        // this one might not be the newest (hence not the first) row.
        let matchQuery = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", uniqueTitle))
        for _ in 0..<15 where matchQuery.count == 0 {
            app.swipeUp()
        }
        XCTAssertEqual(
            matchQuery.count, 1,
            "double-tapping \u{2018}Start from a booking email instead\u{2019} should create exactly one trip, not one per tap"
        )
    }

    // MARK: - P4 milestone screenshots (docs/UX_REDESIGN_ROADMAP.md Phase 4:
    // Share reorder, Settings data-section polish, New-trip cover) — same
    // "config-agnostic test, appearance/Dynamic Type flipped from OUTSIDE
    // between separate invocations" recipe as `testCaptureItineraryScreen`
    // above (see the Tester report for the exact `xcrun simctl ui`
    // commands). Only Share needs all three variants (default light/dark +
    // AX3); Settings and New-trip only need one capture each per the brief.

    /// Reaches `ShareTripView` via `HomeView`'s existing `-uitestOpenShare`
    /// autopilot hook (no new hook added) — chained onto `-uitestOpenFirstTrip`
    /// via the shared `launch(_:)` helper, since that hook requires the trip
    /// screen already pushed (`path.count == 1`).
    ///
    /// Scrolls down to a fixed fraction of the screen — at the default type
    /// size (both the light and dark captures) this comfortably fits the
    /// tail of the people list (role chips included), the invite section,
    /// the public-link Toggle row, and "Forward booking emails" all
    /// together. At AX3 specifically, the same content is too tall for any
    /// one scroll position to fit all of it — this lands on the public-link
    /// Toggle and "Forward booking emails" fully legible (with the invite
    /// section above them), trading off the people list/role chip, which
    /// scrolls out of frame first; see the Tester report for the exact
    /// tradeoff and the other positions tried.
    func testCaptureShareScreen() {
        let app = launch(["-uitestOpenShare"])
        XCTAssertTrue(app.navigationBars["Share this trip"].waitForExistence(timeout: 30), "Share screen never appeared")
        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        start.press(forDuration: 0.05, thenDragTo: end)
        // Waits for the drag's own target ("Forward booking emails," this
        // scroll's whole purpose per the doc comment above) to actually be
        // on screen, rather than guessing the drag's settle time.
        XCTAssertTrue(waitHittable(app.staticTexts["Forward booking emails"]), "drag never scrolled the invite/link section into view")
        attachScreenshot(named: "share", of: app)
    }

    /// `-uitestOpenSettings` (`HomeView`'s existing hook) requires an empty
    /// nav path, so this launches without `-uitestOpenFirstTrip` rather than
    /// through the shared `launch(_:)` helper.
    func testCaptureSettingsScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestOpenSettings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30), "Settings screen never appeared")
        // "Avatar color" is a plain, always-present Profile-section label
        // (unlike "Change photo"/"Add photo", whose text varies with seed
        // state) — waiting for it to be hittable confirms the Form has
        // actually laid out before capturing.
        XCTAssertTrue(waitHittable(app.staticTexts["Avatar color"]), "Settings' Profile section never settled")
        attachScreenshot(named: "settings", of: app)
    }

    /// No autopilot hook exists for the New-trip sheet (nor is one needed —
    /// `planNewTripRow`'s "Plan a new trip" is a plain, always-reachable
    /// button on a freshly-seeded Home). Stays on Home rather than the
    /// shared `launch(_:)` helper's `-uitestOpenFirstTrip`.
    func testCaptureNewTripScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Lisbon"].waitForExistence(timeout: 30), "Home never showed the seeded trip")
        app.buttons["Plan a new trip"].tap()
        let titleField = app.textFields["Lisbon"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "New-trip sheet never appeared")
        // The sheet auto-focuses this field ~0.5s after appearing (`.task`'s
        // create-mode-only delayed focus) — dismiss the keyboard it raises
        // so the cover/shuffle section isn't partly covered by it.
        if app.keyboards.buttons["Done"].waitForExistence(timeout: 2) {
            app.keyboards.buttons["Done"].tap()
        }
        app.swipeUp()
        XCTAssertTrue(waitHittable(app.buttons["Shuffle cover"]), "cover/shuffle section never scrolled into view")
        attachScreenshot(named: "newtrip", of: app)
    }

    // MARK: - P5 register showcase screenshots (docs/UX_REDESIGN_ROADMAP.md
    // Phase 5 verify wave) — same "config-agnostic test, appearance/Dynamic
    // Type flipped from OUTSIDE between separate invocations" recipe as
    // `testCaptureItineraryScreen` above (see the Tester report for the exact
    // `xcrun simctl ui` commands). `DemoSeeder.seed`'s additive
    // `seedRegisterShowcaseTrips` call gives Home a live + future + 3
    // multi-year-past trip alongside "Lisbon", so `.now`/`.plain`/`.been`
    // all render together in one shot. `.next` can never join them —
    // `seedRegisterShowcaseTrips`'s own doc comment (`DemoSeeder.swift`)
    // covers why a live trip's `startDate` always outranks a future one for
    // that single register slot.

    /// Waits on the live "Tokyo Sprint" card specifically (the most
    /// content-heavy new element — today panel + day-progress bar), not
    /// just "Lisbon", so this proves the whole showcase fixture (not only
    /// the original seed) is on screen before capturing. Two captures at
    /// two natural scroll depths, same "one test, two attachments at
    /// different scroll positions" recipe `testCaptureAddItemFlightSheet`
    /// above already uses: `home` at the top (the full register stack —
    /// live + plain ahead cards, "Been there" coming into view), `home-been`
    /// scrolled one screen further so a sticky year header is caught
    /// mid-stick rather than just-arrived at the top of frame.
    func testCaptureHomeRegisterShowcase() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedRegisterShowcase"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your trips"].waitForExistence(timeout: 30), "Home never loaded")
        let liveCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tokyo Sprint")).firstMatch
        XCTAssertTrue(liveCard.waitForExistence(timeout: 30), "live register showcase trip (Tokyo Sprint) never appeared")
        XCTAssertTrue(waitHittable(liveCard), "live register card never settled")
        attachScreenshot(named: "home", of: app)

        // P7 refresh (P6.6): `planNewTripRow` now renders directly above the
        // "been" content (previously the true list foot, below every
        // archive row) — its own dedicated capture, stopping the scroll the
        // moment IT'S hittable, is what actually frames the new order (confirmed
        // empirically: at AX3's much taller rows, this waypoint is too shallow
        // to also carry a real "been" ROW into frame — only the archive
        // header's top edge — so it stays a separate shot rather than
        // replacing `home-been` below, whose own AX3 contract is specifically
        // "been rows in frame," unchanged since before P6.6).
        let planNewTripButton = app.buttons["Plan a new trip"]
        for _ in 0..<15 where !planNewTripButton.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(
            planNewTripButton.isHittable,
            "'Plan a new trip' row (P6.6: now directly above the been archive) never scrolled into view"
        )
        let beenHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Been there")).firstMatch
        XCTAssertTrue(beenHeader.exists, "'Been there' header should already be reachable once 'Plan a new trip' is on screen — it's the very next row (P6.6)")
        XCTAssertTrue(waitHittable(beenHeader), "'Been there' header never actually settled on screen")
        attachScreenshot(named: "home-plan-new-trip-been", of: app)

        // Pre-P6.6 waypoint, unchanged: one page further than "Been there"
        // first appearing, so a sticky year header reads as mid-stick rather
        // than just-arrived — also this scene's own AX3 contract (been ROWS,
        // not just the header, in frame).
        for _ in 0..<15 where !beenHeader.exists {
            app.swipeUp()
        }
        XCTAssertTrue(beenHeader.waitForExistence(timeout: 10), "'Been there' section never scrolled into view")
        app.swipeUp()
        // Kept (test-quality review 2026-07-16): deliberately a proportional
        // "one screen further" position, not tied to any specific row/header
        // becoming hittable (the whole point is a header mid-stick, not
        // just-arrived) — no element changes queryable state at this exact
        // scroll depth to wait on instead.
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "home-been", of: app)

        // P7 award-audit capture set: scroll deeper still, into what's now a
        // 6-row 2025 section (`DemoSeeder`'s additive past trips, alongside
        // "Rome Christmas") — before this addition, every "been" year had
        // only 1-3 rows, short enough that the ENTIRE archive (both years,
        // every row, "Plan a new trip") fit inside about 1.5 screens —
        // confirmed empirically (screenshots from several attempts, at
        // every scroll position reachable at all): a header can't look
        // genuinely "pinned mid-scroll" when there's barely anything left
        // to scroll THROUGH once it appears, headers included. Six rows
        // makes 2025 alone comfortably taller than one screen, so scrolling
        // to its last row necessarily passes through several of its own
        // earlier rows while the "2025" header stays stuck at the top —
        // the actual behavior this scene needs to demonstrate.
        let edinburghRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Edinburgh Fringe")).firstMatch
        for _ in 0..<20 where !edinburghRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(edinburghRow.waitForExistence(timeout: 10), "'Edinburgh Fringe' been row (2025's last) never scrolled into view")
        // The scroll loop above only confirms `.exists` (SwiftUI can
        // instantiate a row before it's actually on screen — same gap
        // `testCaptureItineraryStayStripAndFreeDay`'s own doc comment
        // flags); `isHittable` is what actually confirms the scroll landed.
        XCTAssertTrue(waitHittable(edinburghRow), "'Edinburgh Fringe' row exists but never actually scrolled into view")
        attachScreenshot(named: "home-year-pinned", of: app)
    }

    /// P5.5's "launch always opens at top" contract, verified explicitly
    /// (not just inferred from `HomeView`'s own doc comment): scroll deep,
    /// force-relaunch, and confirm the top ahead card is immediately
    /// hittable with no further scroll — same relaunch recipe
    /// `testDoubleTapStartFromBookingEmailCreatesExactlyOneTrip` above
    /// already uses for a cross-launch assertion.
    func testHomeRegisterShowcaseReopensAtTopAfterDeepScroll() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedRegisterShowcase"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your trips"].waitForExistence(timeout: 30), "Home never loaded")
        let liveCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tokyo Sprint")).firstMatch
        XCTAssertTrue(liveCard.waitForExistence(timeout: 30), "live register showcase trip never appeared")

        // P7d: this used to scroll toward "Plan a new trip" as the "deep
        // enough" waypoint, but P6.6 moved that row to sit directly ABOVE
        // the "been" archive (`HomeView.planNewTripRow`'s own doc comment) —
        // it's no longer the list foot, so reaching it here no longer
        // proves a genuinely deep scroll. "Dublin St. Patrick's" (Mar 2025)
        // has the earliest `endDate` of every seeded past trip
        // (`DemoSeeder.seedRegisterShowcaseTrips`), and `HomeTripOrdering
        // .been`'s most-recent-first sort always renders it dead last — the
        // true bottom of the one-list Home now.
        // `.isHittable`, not `.exists` — SwiftUI's `List` already has every
        // row's button in the accessibility tree pre-scroll (`.exists` would
        // pass after one swipe regardless of position), so hittability is
        // the only honest "actually scrolled into view" signal here.
        let bottomRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Dublin St. Patrick")).firstMatch
        for _ in 0..<50 where !bottomRow.isHittable { app.swipeUp() }
        XCTAssertTrue(bottomRow.isHittable, "'Dublin St. Patrick's' (last been row) never scrolled into view")

        relaunch(app)
        XCTAssertTrue(app.staticTexts["Your trips"].waitForExistence(timeout: 60), "Home never reappeared after relaunch")
        let liveCardAfterRelaunch = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tokyo Sprint")).firstMatch
        XCTAssertTrue(liveCardAfterRelaunch.waitForExistence(timeout: 15), "top card not present right after relaunch")
        XCTAssertTrue(
            liveCardAfterRelaunch.isHittable,
            "P5.5: launch must always open at the top of the list — the live register card should be immediately " +
                "hittable with no scroll needed, even after a deep scroll right before terminating"
        )
    }

    /// "Mid-swipe" on a "been" row, for the register showcase's copy-to-new-
    /// trip affordance (P5.4) — captured right after the swipe reveals the
    /// action, before it's tapped. `.swipeActions` snaps to fully-revealed
    /// or fully-hidden on gesture completion (no true half-dragged state to
    /// hold a screenshot against), so "mid-swipe" here means "revealed, not
    /// yet acted on" — the same state a real screenshot of this moment would
    /// show. If the reveal doesn't settle in time this fails cleanly rather
    /// than hanging; per the brief this shot is skippable if flaky.
    func testCaptureHomeBeenRowSwipeReveal() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedRegisterShowcase"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your trips"].waitForExistence(timeout: 30), "Home never loaded")
        let beenRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Seoul New Year")).firstMatch
        for _ in 0..<15 where !beenRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(beenRow.waitForExistence(timeout: 10), "'Seoul New Year' been row never scrolled into view")
        beenRow.swipeLeft()
        let copyAction = app.buttons["Copy to a new trip"]
        XCTAssertTrue(copyAction.waitForExistence(timeout: 5), "swipe action never revealed")
        XCTAssertTrue(waitHittable(copyAction), "swipe action revealed but never settled on screen")
        attachScreenshot(named: "home-swipe-copy", of: app)
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Condition-based settle waits (replaces fixed `Thread.sleep`
    // "let it settle" waits throughout this file — test-quality review
    // 2026-07-16). `app.screenshot()` (unlike `.tap()`/`waitForExistence`)
    // has none of XCUITest's own action/query quiescence wait built in, so
    // capturing right after a transition genuinely can catch it mid-animation
    // — but the fix is polling the real post-condition, not guessing a fixed
    // duration that's simultaneously too slow on a fast run and too short
    // under CI load. Both route through `XCTNSPredicateExpectation`, XCTest's
    // own periodic-evaluation mechanism, not a hand-rolled sleep loop.

    /// The real post-condition almost every "let the layout/animation settle
    /// before this screenshot" sleep was standing in for: `isHittable`
    /// reflects XCUITest's own resolved on-screen frame, which only reports
    /// true once layout has actually finished moving.
    @discardableResult
    private func waitHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The inverse — waits for a dismissed popover/keyboard element to
    /// actually leave the hierarchy, instead of guessing how long its
    /// dismiss animation takes.
    @discardableResult
    private func waitGone(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// Terminates and relaunches `app` — shared by the two tests that prove
    /// something survives a real process restart. The settle sleep here is
    /// kept deliberately (test-quality review 2026-07-16): `terminate()`
    /// already blocks until the app reports `.notRunning`, so this is purely
    /// simulator/OS-level teardown margin, not app state — there's nothing
    /// left in the accessibility tree to poll once the process is gone.
    private func relaunch(_ app: XCUIApplication) {
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
    }

    // MARK: - P6 milestone screenshots (docs/UX_REDESIGN_ROADMAP.md Phase 6:
    // import-result sheet, duplicate-trip merge, traveller dedupe) — same
    // "config-agnostic test, appearance/Dynamic Type flipped from OUTSIDE
    // between separate invocations" recipe as `testCaptureItineraryScreen`
    // above (see the Tester report for the exact `xcrun simctl ui`
    // commands). `-uitestSeedP6TrustShowcase` (`DemoSeeder`'s additive flag)
    // seeds two same-dates/same-destination "ahead" trips ("Bali Family
    // Trip"/"Bali Getaway") so Home's `DuplicateTripStrip` has a real
    // adjacent pair to fuse under, plus two similarly-named profiles on
    // "Bali Family Trip" so `ShareTripView`'s dedupe banner/review sheet
    // have something to surface. No `-uitestOpenFirstTrip`/`-uitestOpenShare`
    // involved — both target `trips.first?.id`, which on a fresh store is
    // always "Lisbon" (`DemoSeeder.seed`'s own hardcoded return value), not
    // this showcase's trips.

    /// Home's merge strip, then the 6s countdown toast right after tapping
    /// "Merge into…". The countdown is a genuine multi-second STATE (unlike
    /// `testCaptureHomeBeenRowSwipeReveal`'s momentary swipe reveal), so no
    /// held gesture is needed — a screenshot taken right after the tap is
    /// well inside the 6s window. Matches on "Merge into" generically (not
    /// a fixed survivor title): the two seeded trips share an identical
    /// `startDate`, so `HomeTripOrdering.ahead`'s own tie-break
    /// (`id.uuidString`, effectively random per run) decides which one ends
    /// up the strip's survivor.
    func testCaptureHomeMergeStripAndCountdown() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedP6TrustShowcase"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Bali Family Trip"].waitForExistence(timeout: 30), "P6 trust showcase trip never appeared")
        XCTAssertTrue(app.staticTexts["Bali Getaway"].waitForExistence(timeout: 10), "the second duplicate trip never appeared")
        let mergeButton = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Merge into")).firstMatch
        XCTAssertTrue(mergeButton.waitForExistence(timeout: 10), "DuplicateTripStrip's Merge button never appeared")
        XCTAssertTrue(waitHittable(mergeButton), "Merge button never settled on screen")
        attachScreenshot(named: "home-merge-strip", of: app)

        mergeButton.tap()
        // D3(b) (P6 fix round): "Merge" now opens a confirmation dialog
        // BEFORE the countdown starts — tap through it first.
        let confirmButton = app.buttons["Merge"]
        XCTAssertTrue(confirmButton.waitForExistence(timeout: 5), "merge confirmation dialog never appeared")
        // P7 award-audit capture set: the dialog itself, not just tapped
        // through on the way to the countdown toast below.
        XCTAssertTrue(waitHittable(confirmButton), "merge confirmation dialog never settled on screen")
        attachScreenshot(named: "merge-confirm-dialog", of: app)
        confirmButton.tap()

        let undoButton = app.buttons["Undo"]
        XCTAssertTrue(undoButton.waitForExistence(timeout: 5), "merge countdown toast never appeared")
        attachScreenshot(named: "merge-countdown-toast", of: app)
    }

    /// `ShareTripView`'s dedupe banner, then its "Review" destination
    /// (`ProfileDedupeReviewSheet`). Reached by opening "Bali Family Trip"
    /// directly and tapping the hero's own "Share trip" entry point
    /// (`HeroCollapse.swift`), not `-uitestOpenShare` — see this section's
    /// own doc comment for why that hook targets the wrong trip here.
    func testCaptureShareDedupeBannerAndReviewSheet() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedP6TrustShowcase"]
        app.launch()
        let tripCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Bali Family Trip")).firstMatch
        XCTAssertTrue(tripCard.waitForExistence(timeout: 30), "P6 trust showcase trip never appeared on Home")
        tripCard.tap()
        XCTAssertTrue(app.staticTexts["Bali Family Trip"].waitForExistence(timeout: 15), "trip screen never opened")

        let shareButton = app.buttons["Share trip"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10), "hero's Share entry point never appeared")
        shareButton.tap()
        XCTAssertTrue(app.navigationBars["Share this trip"].waitForExistence(timeout: 10), "Share screen never appeared")

        let reviewButton = app.buttons["Review"]
        XCTAssertTrue(reviewButton.waitForExistence(timeout: 10), "dedupe banner's Review button never appeared")
        XCTAssertTrue(waitHittable(reviewButton), "dedupe banner never settled on screen")
        attachScreenshot(named: "share-dedupe-banner", of: app)

        reviewButton.tap()
        XCTAssertTrue(app.navigationBars["Possible duplicates"].waitForExistence(timeout: 5), "dedupe review sheet never presented")
        XCTAssertTrue(waitHittable(app.navigationBars["Possible duplicates"]), "dedupe review sheet never settled on screen")
        attachScreenshot(named: "dedupe-review-sheet", of: app)
    }

    /// N2 (P6 fix round): Settings → `ImportResultSheet` (P6.1), reached via
    /// `-uitestOpenSettings` (existing `HomeView` hook) + the new, additive
    /// `-uitestOpenImportResult` (`SettingsView`'s own hook) rather than a
    /// real archive-file import — `.fileImporter`'s system document picker
    /// isn't drivable the way an in-app sheet is. Deliberately omits
    /// `-uitestOpenFirstTrip`: `-uitestOpenSettings`'s own guard
    /// (`path.isEmpty`) only fires when nothing else has already pushed
    /// onto Home's path first.
    func testCaptureSettingsImportResultSheet() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestOpenSettings", "-uitestOpenImportResult"
        ]
        app.launch()
        XCTAssertTrue(app.staticTexts["Import complete"].waitForExistence(timeout: 30), "ImportResultSheet never appeared")
        XCTAssertTrue(app.staticTexts["Trips"].waitForExistence(timeout: 5), "stat tiles never appeared")
        XCTAssertTrue(waitHittable(app.staticTexts["Trips"]), "stat tiles never settled on screen")
        attachScreenshot(named: "import-result-sheet", of: app)
    }

    // MARK: - P7 award-audit capture set (the full-app visual record for the
    // ux-expert's award audit) — same "config-agnostic test, appearance/
    // Dynamic Type flipped from OUTSIDE between separate invocations" recipe
    // as every capture test above (see the Tester report for the exact
    // `xcrun simctl ui` commands). Several required P7 scenes are already
    // exactly covered by an existing capture test's own attachment —
    // `add-item-flight-preview` (P3), `settings`/`newtrip` (P4),
    // `share-dedupe-banner`/`dedupe-review-sheet`/`import-result-sheet` (P6)
    // — those are re-run for fresh PNGs, not duplicated here; only the
    // scenes with no existing capture get a new test method below.

    /// The "next" register alone — countdown ring + "FIRST UP" strip — the
    /// one register kind no prior phase ever captured visually.
    /// `-uitestSeedRegisterShowcase` (used for the "now"/"been" shots below)
    /// can't show it: that fixture's own live "Tokyo Sprint" always outranks
    /// a future trip for `ahead.first` (see `DemoSeeder
    /// .seedNextRegisterShowcase`'s doc comment), so this uses its own,
    /// separate, live-trip-free seed instead.
    func testCaptureHomeNextRegister() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedNextRegisterShowcase"]
        app.launch()
        let nextCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Marrakech Long Weekend")).firstMatch
        XCTAssertTrue(nextCard.waitForExistence(timeout: 30), "'next' register showcase trip never appeared")
        XCTAssertTrue(waitHittable(nextCard), "'next' register card never settled on screen")
        attachScreenshot(named: "home-next-register", of: app)
    }

    /// P6.5's "Show past trips" off (`SettingsView`'s toggle): the whole
    /// "been" archive collapses into one quiet reveal row ("N past trips
    /// hidden — Show", `HiddenPastTripsRow`) instead of the expanded year-
    /// sectioned list — no prior capture test has ever run with the setting
    /// off. `-showPastTrips NO` needs no app-code hook: it's Foundation's
    /// own `NSUserDefaults` argument-domain convention (a `-key value` pair
    /// in `launchArguments` seeds `UserDefaults` — and so `@AppStorage`
    /// (`HomePastTripsVisibility.appStorageKey`) — before the app ever
    /// runs, the same mechanism `-AppleLanguages` etc. already use
    /// system-wide), reachable on a fresh install with zero production
    /// changes.
    func testCaptureHomePastTripsHiddenRow() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedRegisterShowcase",
            "-showPastTrips", "NO"
        ]
        app.launch()
        let liveCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Tokyo Sprint")).firstMatch
        XCTAssertTrue(liveCard.waitForExistence(timeout: 30), "live register showcase trip (Tokyo Sprint) never appeared")

        let hiddenRow = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "past trip")).firstMatch
        for _ in 0..<15 where !hiddenRow.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(hiddenRow.isHittable, "'N past trips hidden \u{2014} Show' row never scrolled into view")
        // No settle sleep needed: the loop above already polls `isHittable`
        // on this exact row, so it's already confirmed on screen right here.
        attachScreenshot(named: "home-past-trips-hidden", of: app)
    }

    /// Day 1, unscrolled: the conflict banner, both flagged hotel cards
    /// (`hotel1`/`hotel1Duplicate`, the same seeded conflict
    /// `testCaptureItineraryScreen` above already renders), AND the
    /// outbound flight's own boarding pass with its tz-crossing note ("Lands
    /// 20:15 in Lisbon — clocks jump ahead 5h" + the GMT-4/GMT+1 endpoint
    /// labels) — one frame, two required P7 scenes. Not two separate
    /// captures: P1's own ratified decision (DECISIONS.md) folded the
    /// landing tz marker INTO the pass's footer instead of a standalone
    /// rail row, and `-uitestScrollTimeline` (the older hook built for a
    /// separate rail chip) now centers on that same suppressed, invisible
    /// row — confirmed empirically, not assumed — so it adds a pointless
    /// scroll rather than a better one. Lisbon's fixed May 2026 dates are
    /// already behind "today," so the auto-scroll-to-today `.task` never
    /// fires and Day 1 stays at the very top of frame on its own.
    func testCaptureItineraryConflictBanner() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Lisbon"].waitForExistence(timeout: 30), "trip never opened")
        // Same hero-layout-settle reasoning as `testCaptureItineraryScreen`
        // above.
        XCTAssertTrue(waitHittable(app.staticTexts["Lisbon"]), "hero title never became hittable — layout never settled")
        attachScreenshot(named: "itinerary-conflict", of: app)
    }

    /// A mid-stay "night N of M" strip next to a genuinely empty "Free day"
    /// slot — `DemoSeeder`'s additive one-day extension to the register
    /// showcase's "Kyoto Autumn" trip (its hotel's last staying night, then
    /// checkout, then a day nothing else touches). Reached by tapping the
    /// card directly, not `-uitestOpenFirstTrip` — that hook targets
    /// `trips.first?.id`, which is a DIFFERENT (earlier-dated "been") trip
    /// once the showcase exists, the same landmine `seedRegisterShowcaseTrips`'s
    /// own doc comment already flags for every other showcase test above.
    func testCaptureItineraryStayStripAndFreeDay() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedRegisterShowcase"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your trips"].waitForExistence(timeout: 30), "Home never loaded")
        let kyotoCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Kyoto Autumn")).firstMatch
        XCTAssertTrue(kyotoCard.waitForExistence(timeout: 30), "'Kyoto Autumn' register showcase trip never appeared")
        kyotoCard.tap()
        XCTAssertTrue(app.staticTexts["Kyoto Autumn"].waitForExistence(timeout: 15), "trip screen never opened")

        // `isHittable`, not `.exists`: this trip's whole itinerary is short
        // enough (8 one-row days) that SwiftUI's `LazyVStack` had already
        // instantiated the free day row (making it `.exists`) before any
        // scrolling — `.exists` alone exited this loop on the first check
        // and captured the still-at-top screen (confirmed empirically).
        // `isHittable` tracks actual on-screen position instead.
        let freeDayText = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Free day")).firstMatch
        for _ in 0..<15 where !freeDayText.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(freeDayText.isHittable, "the new free day never scrolled into view")
        // No settle sleep needed: the loop above already polls `isHittable`
        // on this exact element, so it's already confirmed on screen here.
        attachScreenshot(named: "itinerary-stay-strip-free-day", of: app)
    }

    /// The Add-item sheet's "get data in" cluster (P4.2) — paste banner +
    /// email-import address card + the category rail, all together at the
    /// sheet's natural, unscrolled top, before typing into anything moves
    /// keyboard focus/auto-scroll further down (unlike
    /// `testCaptureAddItemFlightSheet` above, which fills fields first).
    func testCaptureAddItemPasteAndEmailCluster() {
        let app = launch(["-uitestOpenAdd"])
        let pasteButton = app.buttons["pasteFirstBanner"]
        XCTAssertTrue(pasteButton.waitForExistence(timeout: 30), "Add-item sheet's paste banner never appeared")
        XCTAssertTrue(waitHittable(pasteButton), "paste banner never settled on screen")
        attachScreenshot(named: "add-item-paste-email-cluster", of: app)
    }

    /// Share's people-first list (role chips included), the "Who can do
    /// what" disclosure expanded (tapped open here — collapsed by default,
    /// and no prior capture test has ever expanded it), the public-link row,
    /// and "Forward booking emails," all in one frame.
    ///
    /// Deliberately NOT `-uitestSeedShareAndInvite`: confirmed empirically
    /// (a genuine `Copy link` wait timeout, not a flaky one) that hook can
    /// never populate anything under this whole suite's `-simulateOffline`
    /// convention — `ShareTripView`'s own "Mutations" doc comment says so
    /// directly: creating a share link/invite is "the one deliberate
    /// exception to this app's otherwise-universal offline-first write
    /// path," a real network round-trip with no local-first fallback. That
    /// hook needs a signed, actually-online build (same category as
    /// `LiveAuthWriteTests`, docs/TESTING.md), not this hermetic suite. The
    /// toggle-off public-link row plus the un-created invite buttons are
    /// still a real "link row" — just not a populated one. Same bounded
    /// drag-to-scroll recipe `testCaptureShareScreen` above uses, tuned for
    /// the extra height the now-expanded disclosure adds above the invite/
    /// link sections.
    func testCaptureShareFullPeopleAndLinkRow() {
        let app = launch(["-uitestOpenShare"])
        XCTAssertTrue(app.navigationBars["Share this trip"].waitForExistence(timeout: 30), "Share screen never appeared")

        let disclosureButton = app.buttons["Who can do what"]
        let disclosureText = app.staticTexts["Who can do what"]
        if disclosureButton.waitForExistence(timeout: 10) {
            disclosureButton.tap()
        } else {
            XCTAssertTrue(disclosureText.waitForExistence(timeout: 5), "'Who can do what' disclosure never appeared")
            disclosureText.tap()
        }
        let organizerCapability = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "Everything, incl.")
        ).firstMatch
        XCTAssertTrue(organizerCapability.waitForExistence(timeout: 5), "'Who can do what' disclosure didn't expand")

        let start = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))
        let end = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.28))
        start.press(forDuration: 0.05, thenDragTo: end)
        // Same reasoning as `testCaptureShareScreen` above — waits for the
        // drag's own target rather than guessing its settle time.
        XCTAssertTrue(waitHittable(app.staticTexts["Forward booking emails"]), "drag never scrolled the invite/link section into view")
        attachScreenshot(named: "share-full", of: app)
    }

    /// The signed-out Welcome/sign-in screen — the one screen no existing
    /// capture test reaches (every other one launches straight through
    /// `-uitestAutoSignIn`). Omitting that flag entirely (rather than
    /// `-uitestSignOut`, which drives a real, if `try?`-swallowed,
    /// `Supa.client.auth.signOut()` network call) keeps this launch
    /// hermetic: with no flag, `AuthManager.init` subscribes to the SDK's
    /// `authStateChanges`, which resolves synchronously to "no session"
    /// against a Keychain no test in this suite has ever written a real
    /// session into (every other test's fake session lives only in memory —
    /// see `-uitestAutoSignIn`'s own doc comment).
    func testCaptureWelcomeScreen() {
        let app = XCUIApplication()
        app.launchArguments = ["-simulateOffline"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Tripto"].waitForExistence(timeout: 30), "Welcome screen never appeared")
        XCTAssertTrue(waitHittable(app.staticTexts["Tripto"]), "Welcome screen never settled")
        attachScreenshot(named: "welcome", of: app)
    }

    /// The original boarding-pass-physicality `BookingDetailView`, for a
    /// side-by-side consistency comparison against the new itinerary
    /// timeline's own pass card — same seeded outbound flight
    /// `-uitestOpenBookingDetail` (existing `TripView` hook) already prefers
    /// ("a flight with a confirmation," which the Lisbon fixture's
    /// `TAP TP1234`/`QK7P2M` is). No tear/travel-day flags: this is the
    /// pass's plain resting state, not a torn-stub/mid-tear evidence shot.
    func testCaptureBookingDetailOriginalPass() {
        let app = launch(["-uitestOpenBookingDetail"])
        XCTAssertTrue(app.navigationBars["Booking details"].waitForExistence(timeout: 30), "Booking detail never appeared")
        XCTAssertTrue(waitHittable(app.navigationBars["Booking details"]), "Booking detail screen never settled")
        attachScreenshot(named: "booking-detail-original-pass", of: app)
    }

    // MARK: - P7 refresh: New-trip generated gradient cover (P6.5)

    /// P6.5's generated gradient covers (`CoverGradientGenerator`, mixed in
    /// with the three curated classics by the Shuffle button —
    /// `TripFormView.nextShuffledGradientKey`'s own doc comment: a tap's
    /// `seed` generates a fresh one unless `seed.isMultiple(of: 4)`, i.e.
    /// ~75% of taps generate, the other ~25% cycle to the next curated
    /// classic) — no prior capture test has ever landed on one. The button
    /// fires real entropy per tap (`.random(in: .min...max)` at the call
    /// site, not driveable to a guaranteed outcome from a test), so this
    /// taps Shuffle 8 times, attaching a screenshot after every single tap:
    /// the odds every one of 8 independent taps happens to cycle to a
    /// classic instead is 0.25^8 (\u{2248} 1 in 65,000) — see the Tester
    /// report for which numbered attempt was kept as the final PNG and how
    /// it was confirmed to actually be a generated (non-classic) gradient.
    func testCaptureNewTripGeneratedCoverShuffle() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Lisbon"].waitForExistence(timeout: 30), "Home never showed the seeded trip")
        app.buttons["Plan a new trip"].tap()
        let titleField = app.textFields["Lisbon"]
        XCTAssertTrue(titleField.waitForExistence(timeout: 10), "New-trip sheet never appeared")
        if app.keyboards.buttons["Done"].waitForExistence(timeout: 2) {
            app.keyboards.buttons["Done"].tap()
        }
        app.swipeUp()
        let shuffleButton = app.buttons["Shuffle cover"]
        XCTAssertTrue(shuffleButton.waitForExistence(timeout: 5), "Shuffle cover button never appeared")
        for attempt in 0..<8 {
            shuffleButton.tap()
            // Kept (test-quality review 2026-07-16): each tap redraws the
            // SAME gradient view with new random colors — no accessibility
            // signal distinguishes "still the old gradient" from "the new
            // one," so there's no element/state to wait on here.
            Thread.sleep(forTimeInterval: 0.2)
            attachScreenshot(named: "newtrip-cover-shuffle-\(attempt)", of: app)
        }
    }

    // MARK: - P8a avatar-photos capture set (docs/UX_REDESIGN_ROADMAP.md,
    // `.claude/company/ux-redesign/handoffs/P8-images-plan.md`) — same
    // "config-agnostic test, appearance/Dynamic Type flipped from OUTSIDE
    // between separate invocations" recipe as every capture test above.
    // `-uitestSeedAvatarShowcase` (`DemoSeeder`'s additive flag) seeds the
    // signed-in user's own local `Profile` row with a photo (Settings'
    // profile section otherwise has no row to seed from at all — see the
    // flag's own doc comment) plus a small dedicated "Osaka Weekend" trip
    // with exactly two travellers, Asha (photo) and Kiran (initials only).
    // The photo itself is never a live fetch — `DemoSeeder` primes Nuke's
    // pipeline cache in-process for the exact URL each seeded path derives
    // to, so this stays exactly as hermetic/no-network as the rest of the
    // suite.

    /// `unlinkedProfileRow`'s trailing role-chip `Menu` shares one fixed
    /// "Role: Traveller" accessibility label across every non-account
    /// traveller row on a trip (never the person's own name), so a plain
    /// `app.buttons["Role: Traveller"]` lookup is ambiguous the moment a
    /// trip has more than one — matches by vertical proximity to a
    /// uniquely-named sibling (the traveller's own name `Text`) instead,
    /// rather than depending on `unlinkedProfiles`' sort order.
    private func button(labeled label: String, nearRowOf anchor: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        let candidates = app.buttons.matching(NSPredicate(format: "label == %@", label)).allElementsBoundByIndex
        let anchorMidY = anchor.frame.midY
        return candidates.min { abs($0.frame.midY - anchorMidY) < abs($1.frame.midY - anchorMidY) } ?? app.buttons[label]
    }

    /// Settings' own "Profile" section with a photo already set — the
    /// `AvatarPhotoPicker` row shows "Change photo"/"Remove photo" (rather
    /// than "Add photo" alone) only once `avatarPath` is non-nil, so
    /// asserting on "Change photo" also confirms the seeded photo actually
    /// round-tripped into `SettingsView.myProfile`, not just that Settings
    /// opened. Also the AX3 shot (external Dynamic Type toggle, same
    /// convention as every capture test above).
    func testCaptureSettingsProfilePhoto() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedAvatarShowcase", "-uitestOpenSettings"
        ]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30), "Settings screen never appeared")
        XCTAssertTrue(
            app.buttons["Change photo"].waitForExistence(timeout: 10),
            "seeded avatarPath never rendered the Change/Remove photo pair"
        )
        XCTAssertTrue(waitHittable(app.buttons["Change photo"]), "Change photo row never settled on screen")
        attachScreenshot(named: "settings-profile", of: app)
    }

    /// Home's own `TripCard.AvatarStack(people: people)` (`TripCard.swift`,
    /// via `HomeView.people(for:)`) for "Osaka Weekend" — Asha (photo) and
    /// Kiran (initials) side by side, in the two-circle overlap
    /// `AvatarStack` itself renders. Captured on Home directly, WITHOUT
    /// opening the trip: `TripView`'s own hero (`TripHeroView`) takes only
    /// a bare `tripProfileCount: Int`, never the people array — it renders a
    /// "N people" count pill, not an `AvatarStack` at all (confirmed by
    /// grepping every `AvatarStack(` call site in `Tripto/Sources` — `TripView
    /// .swift`/`TripHeroView.swift` are absent from that list; only
    /// `TripCard.swift`, `HeroFlight.swift` (Home's own live-trip preview),
    /// `BoardingPassCard.swift`, and `TimelineRowViews.swift` (both
    /// per-item assignees) actually use it). Whole-screen capture, same
    /// convention as every other test in this file (`attachScreenshot`'s
    /// own implementation is always a full-screen `app.screenshot()` —
    /// there is no cropping mechanism used anywhere in this suite).
    func testCaptureAvatarStackPhotoAndInitialsSideBySide() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedAvatarShowcase"]
        app.launch()
        let tripCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Osaka Weekend")).firstMatch
        XCTAssertTrue(tripCard.waitForExistence(timeout: 30), "Osaka Weekend showcase trip never appeared on Home")
        // Kept (test-quality review 2026-07-16): lets the card's own photo
        // `LazyImage` settle before capturing — the photo swap has no
        // accessibility signal distinguishing it from the initials
        // placeholder underneath (`AvatarPhotoCircle.accessibilityElement
        // (children: .ignore)` collapses both to one name-only label), so
        // there's no element/state to wait on instead.
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(named: "avatarstack-people", of: app)
    }

    /// `TripProfileFormSheet` in edit mode for Asha (the seeded photo
    /// traveller) — reached via `ShareTripView`'s per-row "Edit" menu
    /// action, not a dedicated autopilot hook (none exists for editing one
    /// specific traveller). Light appearance only, per the brief.
    func testCaptureTripProfileFormSheetWithPhoto() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedAvatarShowcase"]
        app.launch()
        let tripCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Osaka Weekend")).firstMatch
        XCTAssertTrue(tripCard.waitForExistence(timeout: 30), "Osaka Weekend showcase trip never appeared on Home")
        tripCard.tap()
        XCTAssertTrue(app.staticTexts["Osaka Weekend"].waitForExistence(timeout: 15), "trip screen never opened")

        let shareButton = app.buttons["Share trip"]
        XCTAssertTrue(shareButton.waitForExistence(timeout: 10), "hero's Share entry point never appeared")
        shareButton.tap()
        XCTAssertTrue(app.navigationBars["Share this trip"].waitForExistence(timeout: 10), "Share screen never appeared")

        let ashaName = app.staticTexts["Asha"]
        XCTAssertTrue(ashaName.waitForExistence(timeout: 10), "Asha's traveller row never appeared")
        button(labeled: "Role: Traveller", nearRowOf: ashaName, in: app).tap()
        let editAction = app.buttons["Edit"]
        XCTAssertTrue(editAction.waitForExistence(timeout: 5), "the row's Edit/Remove menu never opened")
        editAction.tap()

        XCTAssertTrue(
            app.buttons["Remove photo"].waitForExistence(timeout: 10),
            "TripProfileFormSheet never opened with the seeded photo"
        )
        XCTAssertTrue(waitHittable(app.buttons["Remove photo"]), "TripProfileFormSheet never settled on screen")
        attachScreenshot(named: "tripprofile-photo-light", of: app)
    }

    // MARK: - P8b photo-covers capture set (docs/UX_REDESIGN_ROADMAP.md,
    // trip-covers bucket) — same "config-agnostic test, appearance flipped
    // from OUTSIDE between separate invocations" recipe as every capture
    // test above. `-uitestSeedCoverShowcase` (`DemoSeeder`'s additive flag)
    // seeds "Zanzibar Escape" (ahead, WITH a photo cover — Home card, trip
    // hero, and `TripFormView` edit all read the same seeded
    // `coverImagePath`), "Helsinki Weekend" (ahead, no photo — the
    // gradient-only control, framed alongside "Zanzibar Escape" on Home),
    // and "Santorini Sunset" (been, WITH a photo cover — the 44pt thumb
    // render). The photo itself is never a live fetch — same in-process
    // Nuke memory-cache priming trick `-uitestSeedAvatarShowcase` (P8a)
    // established — so this stays exactly as hermetic/no-network as the
    // rest of the suite. No `-uitestOpenFirstTrip`: that hook targets
    // `trips.first?.id`, which is "Santorini Sunset" (dated 2025, earlier
    // than "Lisbon") once this showcase exists — the same landmine
    // `seedRegisterShowcaseTrips`'s own doc comment already flags for every
    // other showcase above; every test below finds its trip by title
    // directly instead.

    /// Home's own card for "Zanzibar Escape" (photo cover) framed alongside
    /// "Helsinki Weekend" (gradient only, no photo) in the SAME screenshot —
    /// the "photo vs. gradient" comparison this milestone's brief asked for,
    /// same "put the comparison in one shot" recipe
    /// `testCaptureAvatarStackPhotoAndInitialsSideBySide` (P8a) already
    /// established for photo-vs-initials. Captured in both appearances
    /// (external `xcrun simctl ui` flip, see the Tester report) since the
    /// brief calls out glass-pill legibility over a PHOTO specifically in
    /// both light and dark, not just the gradient case every existing
    /// capture already covers.
    func testCaptureHomeCoverPhotoCardAndGradientControl() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedCoverShowcase"]
        app.launch()
        let photoCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Zanzibar Escape")).firstMatch
        XCTAssertTrue(photoCard.waitForExistence(timeout: 30), "'Zanzibar Escape' cover-photo showcase trip never appeared")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Helsinki Weekend")).firstMatch.exists,
            "'Helsinki Weekend' gradient-only control trip never appeared alongside it"
        )
        // Kept (test-quality review 2026-07-16, same reasoning as
        // `testCaptureAvatarStackPhotoAndInitialsSideBySide` above): lets the
        // card's own cover-photo `LazyImage` settle — no accessibility
        // signal distinguishes the loaded photo from the gradient
        // placeholder underneath (`CoverImage`'s own doc comment: "the
        // gradient always renders first... a LazyImage layered on top").
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(named: "home-cover-photo", of: app)
    }

    /// The trip hero itself, with a photo layered over its gradient
    /// (`TripHeroView`'s own `CoverImage`) — expanded (the natural, just-
    /// opened state) and then collapsed (scrolled past `HeroCollapse
    /// .collapseDistance`). Light only, per the brief. Scrolls to "Day 7"
    /// (the LAST day, well below the fold even with the seeded multi-night
    /// hotel stay's own extra height — confirmed empirically: "Day 2"'s own
    /// content, tried first, already sits inside the unscrolled viewport, so
    /// a loop exiting on ITS visibility never actually swipes) — `isHittable`,
    /// not `.exists`, matching `testCaptureItineraryStayStripAndFreeDay`'s
    /// own reasoning: a row can already be instantiated (and thus `.exists`)
    /// before any real scrolling, so only `isHittable` (on-screen position)
    /// actually confirms the scroll landed.
    func testCaptureTripHeroCoverPhotoExpandedAndCollapsed() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedCoverShowcase"]
        app.launch()
        let photoCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Zanzibar Escape")).firstMatch
        XCTAssertTrue(photoCard.waitForExistence(timeout: 30), "'Zanzibar Escape' cover-photo showcase trip never appeared")
        photoCard.tap()
        XCTAssertTrue(app.staticTexts["Zanzibar Escape"].waitForExistence(timeout: 15), "trip screen never opened")

        // Kept (test-quality review 2026-07-16): the hero's one-shot layout
        // measurement AND its cover-photo LazyImage both need to settle here
        // — the layout half alone would be a `waitHittable` (as
        // `testCaptureItineraryScreen` now uses for its own hero), but the
        // LazyImage half has no accessibility signal to wait on instead (see
        // `testCaptureHomeCoverPhotoCardAndGradientControl`'s own note), and
        // that's the binding constraint, so this stays a plain sleep rather
        // than a wait that would only cover half the settle this needs.
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(named: "trip-hero-cover-photo", of: app)

        let lastDayText = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Day 7")).firstMatch
        for _ in 0..<15 where !lastDayText.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(lastDayText.isHittable, "itinerary never scrolled — nothing to collapse the hero against")
        // No settle sleep needed: `HeroCollapse`'s collapse fraction is a
        // pure function of the live scroll offset (no `withAnimation`/spring
        // involved — confirmed in `HeroCollapse.swift`), and the loop above
        // already polls `isHittable` on this exact element, so the hero is
        // already in its final collapsed state here.
        attachScreenshot(named: "trip-hero-cover-photo-collapsed", of: app)
    }

    /// A "been" register row with a photo thumb — `BeenRow`'s own 44pt
    /// `CoverImage(resizeTo:)` branch. Light only, per the brief. Same
    /// bounded-swipe-until-visible recipe `testCaptureHomeBeenRowSwipeReveal`
    /// already uses for a different been row.
    func testCaptureHomeBeenRowCoverPhotoThumb() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedCoverShowcase"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your trips"].waitForExistence(timeout: 30), "Home never loaded")
        let beenRow = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Santorini Sunset")).firstMatch
        for _ in 0..<15 where !beenRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(beenRow.waitForExistence(timeout: 10), "'Santorini Sunset' cover-photo been row never scrolled into view")
        // `.exists` alone (the loop's own gate above) doesn't confirm actual
        // on-screen position — `isHittable` does.
        XCTAssertTrue(waitHittable(beenRow), "'Santorini Sunset' row exists but never actually scrolled into view")
        attachScreenshot(named: "home-been-cover-photo", of: app)
    }

    /// `TripFormView` in edit mode (reached via the hero's own pencil, the
    /// discoverable organizer edit entry point — `HeroCollapse.swift`'s
    /// `GlassCircleButton(accessibilityLabel: "Edit trip")`) on the trip
    /// whose `coverImagePath` this showcase already seeded — "Change
    /// photo"/"Remove photo" render immediately, with no `PhotosPicker`
    /// interaction needed (that system UI isn't something XCUITest in this
    /// suite ever drives). Light only, per the brief.
    func testCaptureTripFormCoverPhotoChangeAndRemove() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedCoverShowcase"]
        app.launch()
        let photoCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Zanzibar Escape")).firstMatch
        XCTAssertTrue(photoCard.waitForExistence(timeout: 30), "'Zanzibar Escape' cover-photo showcase trip never appeared")
        photoCard.tap()
        XCTAssertTrue(app.staticTexts["Zanzibar Escape"].waitForExistence(timeout: 15), "trip screen never opened")

        let editButton = app.buttons["Edit trip"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "hero's pencil edit entry point never appeared")
        editButton.tap()

        XCTAssertTrue(
            app.buttons["Remove photo"].waitForExistence(timeout: 10),
            "TripFormView never opened with the seeded cover photo"
        )
        XCTAssertTrue(app.buttons["Change photo"].exists, "the picker row must read \"Change photo\", not \"Choose a photo\"")
        XCTAssertTrue(waitHittable(app.buttons["Remove photo"]), "TripFormView's cover section never settled on screen")
        attachScreenshot(named: "tripform-cover-photo", of: app)
    }

    // MARK: - P8c cover-search capture set (`CoverSearchSheet` — results
    // grid, empty state, error state — plus `TripFormView`'s own
    // searched-cover credit line) + the rapid-query-change hardening test.
    // `DemoSeeder`'s additive `CoverSearchStubURLProtocol`
    // (`-uitestStubCoverSearch{Results,Empty,Error}`) stands in for the
    // real `search-covers` edge function exactly the way P8a/P8b's own Nuke
    // memory-cache priming stands in for a live image fetch — hermetic, no
    // network, same "own flag, additive" recipe. See that type's own doc
    // comment (`DemoSeeder.swift`) for the exact wiring: a process-wide
    // `URLProtocol` intercepting the one live network call
    // `SupabaseCoverSearchProvider` makes, never registered absent one of
    // those three flags.

    /// Reaches `CoverSearchSheet` via the seeded "Lisbon" trip's own edit
    /// sheet ("Search photos", beside "Choose a photo") — no dedicated
    /// autopilot hook needed, `TripFormView`'s "Edit trip" pencil is already
    /// reachable via the shared `launch(_:)` helper's `-uitestOpenFirstTrip`.
    private func openCoverSearchSheet(extraArgs: [String]) -> XCUIApplication {
        let app = launch(extraArgs)
        let editButton = app.buttons["Edit trip"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 30), "hero's pencil edit entry point never appeared")
        editButton.tap()
        let searchPhotosButton = app.buttons["Search photos"]
        XCTAssertTrue(searchPhotosButton.waitForExistence(timeout: 10), "TripFormView never opened")
        searchPhotosButton.tap()
        let searchField = app.textFields["mountains, beaches, cities\u{2026}"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 10), "CoverSearchSheet's own search field never appeared")
        return app
    }

    /// The results grid, both credit layers visible at once (the header's
    /// persistent "Photos provided by Pexels" link + each result's own
    /// "Photo by {name}" caption) — `DemoSeeder`'s `-uitestStubCoverSearchResults`
    /// canned six photographers, standing in for a live `search-covers`
    /// response. Config-agnostic (appearance/Dynamic Type flipped from
    /// OUTSIDE between separate invocations, same recipe as every other
    /// capture test in this file — see the Tester report for the exact
    /// `xcrun simctl` commands).
    func testCaptureCoverSearchResultsGrid() {
        let app = openCoverSearchSheet(extraArgs: ["-uitestStubCoverSearchResults"])
        let searchField = app.textFields["mountains, beaches, cities\u{2026}"]
        searchField.tap()
        searchField.typeText("mountains")
        let firstResult = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Aiko Tanaka")).firstMatch
        XCTAssertTrue(firstResult.waitForExistence(timeout: 10), "the stubbed results grid never rendered")
        // Dismisses the keyboard (submits, same `.onSubmit { searchFocused =
        // false }` the field itself wires up) — at AX3 specifically, the
        // keyboard otherwise eats enough of the sheet's own scarce vertical
        // space to cut a result's own caption off entirely, defeating the
        // "both credit layers visible" ask this scene exists for.
        searchField.typeText("\n")
        XCTAssertTrue(waitGone(app.keyboards.firstMatch), "keyboard never dismissed")
        attachScreenshot(named: "cover-search-results", of: app)
    }

    /// A query the stub maps to a successful-but-empty page —
    /// `content`'s own `case .loaded where photos.isEmpty` branch, not the
    /// error branch (`FunctionsError` is never thrown here). Light only.
    func testCaptureCoverSearchEmptyState() {
        let app = openCoverSearchSheet(extraArgs: ["-uitestStubCoverSearchEmpty"])
        app.textFields["mountains, beaches, cities\u{2026}"].tap()
        app.textFields["mountains, beaches, cities\u{2026}"].typeText("zzzznoresults")
        let emptyMessage = app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "No photos found")).firstMatch
        XCTAssertTrue(emptyMessage.waitForExistence(timeout: 10), "the empty state never rendered")
        XCTAssertTrue(waitHittable(emptyMessage), "empty state never settled on screen")
        attachScreenshot(named: "cover-search-empty", of: app)
    }

    /// A thrown `FunctionsError.httpError(503, ...)` — `CoverSearchSheet
    /// .friendlyMessage(for:)`'s own Pexels-unavailable copy, plus the "Try
    /// again" retry button. Light only.
    func testCaptureCoverSearchErrorState() {
        let app = openCoverSearchSheet(extraArgs: ["-uitestStubCoverSearchError"])
        app.textFields["mountains, beaches, cities\u{2026}"].tap()
        app.textFields["mountains, beaches, cities\u{2026}"].typeText("beaches")
        let retryButton = app.buttons["Try again"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 10), "the error state's retry button never appeared")
        XCTAssertTrue(waitHittable(retryButton), "error state never settled on screen")
        attachScreenshot(named: "cover-search-error", of: app)
    }

    /// `TripFormView`'s own credit-render slot (`coverPhotoCreditLine`) with
    /// a trip that's ALREADY carrying a Pexels credit — reached via
    /// `-uitestSeedCoverShowcase`'s existing "Zanzibar Escape" seed (P8b),
    /// which this pass additively seeds with a `coverCreditName`/
    /// `coverCreditUrl` pair too (`DemoSeeder.seedCoverShowcase`'s own doc
    /// comment) rather than driving a live `CoverSearchSheet` search-and-pick
    /// — that pipeline ends in a real Storage upload, not reachable in this
    /// hermetic suite (`CoverSearchStubURLProtocol`'s own doc comment covers
    /// why only the search RESPONSE, not the pick pipeline, is stubbed).
    /// Light only, per the brief; the 12.5pt legibility-fix credit line is
    /// this scene's own point, not a new appearance variant.
    func testCaptureTripFormSearchedCoverCreditLine() {
        let app = XCUIApplication()
        app.launchArguments = ["-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedCoverShowcase"]
        app.launch()
        let photoCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Zanzibar Escape")).firstMatch
        XCTAssertTrue(photoCard.waitForExistence(timeout: 30), "'Zanzibar Escape' cover-photo showcase trip never appeared")
        photoCard.tap()
        XCTAssertTrue(app.staticTexts["Zanzibar Escape"].waitForExistence(timeout: 15), "trip screen never opened")

        let editButton = app.buttons["Edit trip"]
        XCTAssertTrue(editButton.waitForExistence(timeout: 10), "hero's pencil edit entry point never appeared")
        editButton.tap()

        // Type-agnostic (`.any`, not `.links`/`.buttons`): SwiftUI `Link`'s
        // own XCUITest element type isn't pinned down elsewhere in this
        // suite, so this matches on label alone regardless of which
        // container type it surfaces as.
        let creditLine = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Priya Nair")).firstMatch
        XCTAssertTrue(creditLine.waitForExistence(timeout: 10), "the searched-cover credit line never rendered")
        // `.exists` alone isn't enough — at AX3 this sheet's own `ScrollView`
        // no longer fits the credit line (below the Cover section) in the
        // unscrolled viewport, confirmed empirically the same way
        // `testCaptureTripHeroCoverPhotoExpandedAndCollapsed` already had to
        // account for. `isHittable` (on-screen position) is what actually
        // confirms the scroll landed; at default type size the line already
        // fits, so this loop performs zero swipes there.
        for _ in 0..<15 where !creditLine.isHittable {
            app.swipeUp()
        }
        XCTAssertTrue(creditLine.isHittable, "the credit line never scrolled into frame")
        // No settle sleep needed: the loop above already polls `isHittable`
        // on this exact element, so it's already confirmed on screen here.
        attachScreenshot(named: "tripform-searched-cover-credit-light", of: app)
    }

    /// JOB A hardening, at the level that actually matters: the real view's
    /// `.task(id: query)` + `runSearch()`'s own `guard !Task.isCancelled
    /// else { return }` (both private/`@State`-bound, unreachable from
    /// `TriptoTests` without a SwiftUI-hosting harness this codebase
    /// doesn't have — see `CoverSearchSheetTests
    /// .testTaskCancelledBeforeASlowProviderCallResolvesStillReadsCancelled
    /// OnceItResumes` for the one-level-down mechanical-contract proxy, and
    /// the Tester report for the exact gap). A query containing "slow" gets
    /// an exaggerated artificial delay from `CoverSearchStubURLProtocol`
    /// (~1.2s) specifically so a fast query typed shortly after has time to
    /// actually supersede it while still in flight, not just in theory:
    /// types a slow query, waits past the 400ms debounce (so the request
    /// has actually STARTED, not merely been debounced away), types a fast
    /// query before the slow one resolves, then waits past when the slow
    /// one WOULD have resolved. The stale "Stale Slow Result" caption must
    /// never surface, at any point — not while waiting, and not once its
    /// own artificial delay elapses.
    func testRapidQueryChangeNeverLetsAStaleSlowResultSurface() {
        let app = openCoverSearchSheet(extraArgs: ["-uitestStubCoverSearchResults"])
        let searchField = app.textFields["mountains, beaches, cities\u{2026}"]
        searchField.tap()
        let slowQuery = "slowquery"
        searchField.typeText(slowQuery)
        // Kept (test-quality review 2026-07-16): the real post-condition the
        // 400ms debounce gates is `runSearch()` setting `state = .loading`
        // (`CoverSearchSheet.swift`), which renders a bare `ProgressView`
        // with no accessibility identifier/label of its own (app sources are
        // off limits from this worktree, so one can't be added here) —
        // tried waiting on `app.activityIndicators.firstMatch` first, but
        // empirically (a real run against the built app) it never matched
        // this view within the loading window, so reverted rather than ship
        // an unverified wait. Past the 400ms debounce — the slow request
        // has actually started (and is now in flight, ~1.2s from resolving)
        // before it gets superseded below.
        Thread.sleep(forTimeInterval: 0.6)

        // A plain `typeText` APPENDS after the cursor, and a query merely
        // containing "slowquery" as a substring would still read as "slow"
        // to the stub — clears it first, character by character, rather
        // than leaving a hybrid string behind.
        searchField.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: slowQuery.count))
        searchField.typeText("fastmountain")

        let freshResult = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Aiko Tanaka")).firstMatch
        XCTAssertTrue(freshResult.waitForExistence(timeout: 10), "the fresh (fast) query's own results never rendered")
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Stale Slow Result")).count, 0,
            "the stale slow query's result must never surface once superseded"
        )

        // Kept (test-quality review 2026-07-16): waits past when the stale
        // slow request WOULD have resolved (~1.2s artificial delay, well
        // covered from here), then re-checks that a late-arriving stale
        // result never retroactively appears. This is a negative/absence
        // assertion — there's no event to wait FOR, only a risk window that
        // has to fully elapse before "it never showed" means anything.
        Thread.sleep(forTimeInterval: 2.0)
        XCTAssertEqual(
            app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Stale Slow Result")).count, 0,
            "a late-arriving stale result must never surface even after its own artificial delay elapses"
        )
        XCTAssertTrue(freshResult.exists, "the fresh query's own result must still be showing")
    }

    // MARK: - Release 1.1 App Store screenshot refresh (WP5a)
    //
    // Distinct from every `testCaptureXxxScreen` milestone-review test
    // above: those all launch through the shared `launch(_:)` helper (or an
    // inline equivalent) with `-simulateOffline` and no `-screenshotMode` —
    // fine for internal design/eng review, but that combination shows
    // Home's debug ladybug menu, which the shipped marketing set has never
    // shown. These two methods instead add `-screenshotMode`, and — unlike
    // every plan for this recipe that starts from docs/RELEASE_READINESS.md
    // §7's own literal BASE string — deliberately KEEP `-simulateOffline`
    // rather than drop it.
    //
    // That doc's BASE omits `-simulateOffline`, and this file's own top doc
    // comment explains why every OTHER test here still pairs it with
    // `-uitestAutoSignIn`: without it, `-uitestAutoSignIn`'s fixed fake
    // bearer token still lets `SyncEngine.start()` reach the real backend
    // (`isEffectivelyOffline` only reflects `-simulateOffline`/genuine
    // `NWPathMonitor` state, never auth validity). Confirmed live, the hard
    // way (a first attempt at this WP without `-simulateOffline`, kept only
    // as this comment now): the fake token doesn't hard-401 — it reaches
    // PostgREST as an unauthenticated/RLS-scoped request, which succeeds
    // with an EMPTY result. `SyncStore.applyTrips`/`pruneOrphans` then read
    // that empty pull as "every local trip was deleted server-side" the
    // moment DemoSeeder's own seed push (also real, also rejected) drops a
    // row out of the protecting `pendingIds` set — caught only by this
    // capture's own mandatory eyeball pass: a live run produced a red
    // "Couldn't save 70 changes" `SyncIssueBanner`, an itinerary emptied
    // back to "Add your first flight, stay, or plan," a booking item
    // replaced by "This item is no longer available," and a Share people
    // list collapsed to "ON THIS TRIP · 0." `-simulateOffline` is the only
    // launch-arg-level lever that pauses both push AND pull
    // (`SyncEngine.isEffectivelyOffline`), and it's the one this whole
    // suite already relies on everywhere else — correct, uncorrupted
    // content wins over exactly matching that one doc's BASE string.
    //
    // The tradeoff: `SyncBanner` (the amber "Offline — changes will sync…"
    // strip) renders whenever `SyncStatus.isOffline` is true, forced or
    // real, with no way to distinguish the two — and it's wired into
    // `HomeView`/`TripView` only (confirmed by grep; `BookingDetailView`/
    // `ShareTripView`/`SettingsView`/`PrivacySummaryView` never render
    // either sync banner). So `store-01-home`, `store-02-itinerary`, and
    // `store-05-packing` (all Home- or TripView-bodied) DO show that amber
    // strip — a real, deliberate, documented deviation from the pre-1.1 set
    // (which shows no banner at all) — while boarding/share/privacy stay
    // exactly as clean as before, unaffected either way. See the Coder
    // report for this WP for the full tradeoff writeup and a suggested
    // follow-up (extending `-screenshotMode` to also suppress the sync
    // banners, the same "clean for App Store captures" intent it already
    // serves for the debug menu) — out of scope here since it would touch
    // production `HomeView`/`TripView` source, not just this test file.

    /// 01-home + 02-itinerary: the photo-cover trip as Home's hero card
    /// alongside a gradient-only card, then that same trip's own hero
    /// (bounded photo + tabs on paper) — the 1.1 marquee feature this
    /// refresh exists to showcase. `-uitestSeedCoverShowcase` seeds
    /// "Zanzibar Escape" (photo, ahead) alongside "Helsinki Weekend"
    /// (gradient, ahead); deliberately NO `-uitestSeedToday` — shifting
    /// "Lisbon" onto today's date would make it the live/"now" register
    /// slot and outrank Zanzibar for the hero position
    /// (`seedRegisterShowcaseTrips`'s own doc comment: a live trip always
    /// outranks a future one there), which is exactly the slot this capture
    /// needs Zanzibar to hold instead. Same "no accessibility signal for a
    /// loaded LazyImage, so a bounded settle sleep is the deliberate
    /// exception" reasoning as `testCaptureHomeCoverPhotoCardAndGradientControl`/
    /// `testCaptureTripHeroCoverPhotoExpandedAndCollapsed` above.
    func testCaptureAppStorePhotoCoverScreens() {
        let app = XCUIApplication()
        app.launchArguments = [
            "-screenshotMode", "-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedCoverShowcase"
        ]
        app.launch()
        let photoCard = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Zanzibar Escape")).firstMatch
        XCTAssertTrue(photoCard.waitForExistence(timeout: 30), "'Zanzibar Escape' cover-photo trip never appeared")
        XCTAssertTrue(
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Helsinki Weekend")).firstMatch.exists,
            "gradient-only control trip never appeared alongside it"
        )
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(named: "store-01-home", of: app)

        photoCard.tap()
        XCTAssertTrue(app.staticTexts["Zanzibar Escape"].waitForExistence(timeout: 15), "trip screen never opened")
        Thread.sleep(forTimeInterval: 1.5)
        attachScreenshot(named: "store-02-itinerary", of: app)
    }

    /// 03-boarding, 04-share, 05-packing, 06-privacy: the same four scenes
    /// docs/RELEASE_READINESS.md §7 names, on "Lisbon" (today-shifted via
    /// `-uitestSeedToday` so the itinerary's "Now" line and the boarding
    /// pass's travel-day pill both read live), each its own terminate +
    /// relaunch with that scene's own launch-arg combo — matches the doc's
    /// "per screen: terminate, launch with the screen's arg(s)" recipe.
    /// Sequential relaunches within this one method reuse the same
    /// already-seeded "Lisbon" every time (same "seeded trip persists
    /// across relaunches" convention this file's other tests already rely
    /// on, e.g. `testDoubleTapSaveCreatesAtMostOneFlightItem`) since none of
    /// these launches carry a showcase flag
    /// (`HomeView.applyUITestAutopilotIfNeeded`'s `needsShowcaseReset` never
    /// trips), so there's no risk of the store being wiped/re-seeded
    /// mid-method.
    func testCaptureAppStoreLisbonScreens() {
        let baseArgs = ["-screenshotMode", "-uitestAutoSignIn", "-simulateOffline", "-uitestSeedIfEmpty", "-uitestSeedToday"]
        let app = XCUIApplication()

        app.launchArguments = baseArgs + ["-uitestOpenFirstTrip", "-uitestOpenBookingDetail"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Booking details"].waitForExistence(timeout: 30), "Booking detail never appeared")
        XCTAssertTrue(waitHittable(app.navigationBars["Booking details"]), "Booking detail screen never settled")
        attachScreenshot(named: "store-03-boarding", of: app)
        app.terminate()
        // Same "purely simulator/OS-level teardown margin" reasoning as
        // `relaunch(_:)`'s own settle sleep above.
        Thread.sleep(forTimeInterval: 1.0)

        app.launchArguments = baseArgs + ["-uitestOpenFirstTrip", "-uitestOpenShare"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Share this trip"].waitForExistence(timeout: 30), "Share screen never appeared")
        XCTAssertTrue(waitHittable(app.navigationBars["Share this trip"]), "Share screen never settled")
        attachScreenshot(named: "store-04-share", of: app)
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)

        app.launchArguments = baseArgs + ["-uitestOpenFirstTrip", "-uitestOpenPacking"]
        app.launch()
        let packingFab = app.buttons["Add a packing item"]
        XCTAssertTrue(packingFab.waitForExistence(timeout: 30), "Packing tab never appeared")
        XCTAssertTrue(waitHittable(packingFab), "Packing tab never settled")
        attachScreenshot(named: "store-05-packing", of: app)
        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)

        app.launchArguments = baseArgs + ["-uitestOpenSettings"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 30), "Settings screen never appeared")
        // "Privacy" (About section) sits below Profile/Delete-account/Data —
        // confirmed off-screen on first render (a live run's own "Vertical
        // scroll bar, 2 pages" accessibility snapshot) — same bounded-swipe
        // recipe `testCaptureHomeBeenRowSwipeReveal` uses for a different
        // below-the-fold row.
        let privacyRow = app.buttons["Privacy"]
        for _ in 0..<15 where !privacyRow.exists {
            app.swipeUp()
        }
        XCTAssertTrue(privacyRow.waitForExistence(timeout: 10), "Privacy row never scrolled into view")
        XCTAssertTrue(waitHittable(privacyRow), "Privacy row exists but never actually scrolled into view")
        privacyRow.tap()
        let privacyTitle = app.navigationBars["Your privacy at a glance"]
        XCTAssertTrue(privacyTitle.waitForExistence(timeout: 10), "Privacy screen never opened")
        XCTAssertTrue(waitHittable(privacyTitle), "Privacy screen never settled")
        attachScreenshot(named: "store-06-privacy", of: app)
    }
}
