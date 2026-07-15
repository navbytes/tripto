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
        app.terminate()
        // Lets the simulator finish tearing down the old process before
        // asking for a new one — this machine's `xcodebuild test` runs have
        // shown general launch/relaunch slowness independent of this test
        // (matches the P4 handoff's own noted pre-existing flakiness).
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
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
        Thread.sleep(forTimeInterval: 0.3)
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
        Thread.sleep(forTimeInterval: 0.3)
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
        Thread.sleep(forTimeInterval: 0.3)
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
        Thread.sleep(forTimeInterval: 0.5)
        attachScreenshot(named: "home", of: app)

        let beenHeader = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Been there")).firstMatch
        for _ in 0..<15 where !beenHeader.exists {
            app.swipeUp()
        }
        XCTAssertTrue(beenHeader.waitForExistence(timeout: 10), "'Been there' section never scrolled into view")
        // One more page down so a year header sits pinned mid-scroll rather
        // than just-arrived at the very top of frame.
        app.swipeUp()
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "home-been", of: app)
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

        for _ in 0..<15 { app.swipeUp() } // scroll deep toward "Plan a new trip"
        let planRow = app.buttons["Plan a new trip"]
        XCTAssertTrue(planRow.waitForExistence(timeout: 10), "'Plan a new trip' row never scrolled into view")

        app.terminate()
        Thread.sleep(forTimeInterval: 1.0)
        app.launch()
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
        Thread.sleep(forTimeInterval: 0.2)
        attachScreenshot(named: "home-swipe-copy", of: app)
    }

    private func attachScreenshot(named name: String, of app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
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
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "home-merge-strip", of: app)

        mergeButton.tap()
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
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "share-dedupe-banner", of: app)

        reviewButton.tap()
        XCTAssertTrue(app.navigationBars["Possible duplicates"].waitForExistence(timeout: 5), "dedupe review sheet never presented")
        Thread.sleep(forTimeInterval: 0.3)
        attachScreenshot(named: "dedupe-review-sheet", of: app)
    }
}
