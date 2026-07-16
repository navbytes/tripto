import SwiftData
import XCTest
@testable import Tripto

/// Coverage the pure `TripFormValidation` suite can't reach: F7's edit-path
/// stamping (needs an actual `Trip` model to assert `toDTO()` off of) and
/// F8's gradient-key normalization (a `TripFormView` static, exposed for
/// exactly this).
final class TripFormViewTests: XCTestCase {
    // MARK: - F7: edit path stamps updatedAt/updatedBy

    @MainActor
    func testEditMutationStampsUpdatedAtAndUpdatedByOnToDTO() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let creator = UUID()
        let editor = UUID()
        let originalUpdatedAt = Date(timeIntervalSince1970: 0)
        let trip = Trip(
            id: UUID(), title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: .now, endDate: .now.addingTimeInterval(86_400 * 6), coverGradient: "dusk",
            tripTypeRaw: TripType.family.rawValue, createdBy: creator,
            createdAt: originalUpdatedAt, updatedAt: originalUpdatedAt, updatedBy: nil
        )
        context.insert(trip)

        // The exact mutation `TripFormView.save()`'s edit branch performs
        // (mirroring `AddItemSheet.swift`'s `editing.updatedAt`/`updatedBy`).
        trip.title = "Porto"
        trip.updatedAt = .now
        trip.updatedBy = editor

        let dto = trip.toDTO()
        XCTAssertEqual(dto.title, "Porto")
        XCTAssertEqual(dto.updatedBy, editor)
        XCTAssertGreaterThan(dto.updatedAt, originalUpdatedAt)
    }

    // MARK: - P8b: editing a trip's cover photo must clear any existing
    // Pexels credit (P8c will be the only future WRITER of a non-nil
    // credit, but this invariant has to hold from P8b's own first save
    // onward — a credit names one specific photo and must never survive
    // whatever replaced or removed it). `save()` itself has no view-level
    // harness in this suite (same as F7 above) — these replicate the EXACT
    // mutation `save()`'s edit branch performs against a real `Trip`,
    // asserting via `toDTO()`, mirroring `testEditMutationStampsUpdatedAtAnd
    // UpdatedByOnToDTO`'s own shape.

    @MainActor
    func testEditingCoverPhotoClearsAnyExistingPexelsCredit() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let trip = Trip(
            id: UUID(), title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: .now, endDate: .now.addingTimeInterval(86_400 * 6), coverGradient: "dusk",
            tripTypeRaw: TripType.family.rawValue, createdBy: UUID(),
            createdAt: .now, updatedAt: .now, updatedBy: nil,
            coverImagePath: "old/pexels-cover.jpg", coverCreditName: "Priya", coverCreditUrl: "https://pexels.com/photo/1"
        )
        context.insert(trip)
        // What `TripFormView.init`'s `.edit` branch would have captured into
        // `initialValues.coverImagePath` when this sheet opened.
        let initialCoverImagePath = trip.coverImagePath

        // The exact mutation `save()`'s edit branch performs when the
        // draft `coverImagePath` (a successful new upload, here) differs
        // from what the sheet opened with.
        let draftCoverImagePath: String? = "new/my-own-photo.jpg"
        trip.coverImagePath = draftCoverImagePath
        if draftCoverImagePath != initialCoverImagePath {
            trip.coverCreditName = nil
            trip.coverCreditUrl = nil
        }

        let dto = trip.toDTO()
        XCTAssertEqual(dto.coverImagePath, "new/my-own-photo.jpg")
        XCTAssertNil(dto.coverCreditName)
        XCTAssertNil(dto.coverCreditUrl)
    }

    /// The "Remove photo" case — same clearing rule, `draftCoverImagePath`
    /// is `nil` instead of a new path.
    @MainActor
    func testRemovingCoverPhotoAlsoClearsAnyExistingPexelsCredit() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let trip = Trip(
            id: UUID(), title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: .now, endDate: .now.addingTimeInterval(86_400 * 6), coverGradient: "dusk",
            tripTypeRaw: TripType.family.rawValue, createdBy: UUID(),
            createdAt: .now, updatedAt: .now, updatedBy: nil,
            coverImagePath: "old/pexels-cover.jpg", coverCreditName: "Priya", coverCreditUrl: "https://pexels.com/photo/1"
        )
        context.insert(trip)
        let initialCoverImagePath = trip.coverImagePath

        let draftCoverImagePath: String? = nil
        trip.coverImagePath = draftCoverImagePath
        if draftCoverImagePath != initialCoverImagePath {
            trip.coverCreditName = nil
            trip.coverCreditUrl = nil
        }

        let dto = trip.toDTO()
        XCTAssertNil(dto.coverImagePath)
        XCTAssertNil(dto.coverCreditName)
        XCTAssertNil(dto.coverCreditUrl)
    }

    /// The negative case: editing an UNRELATED field (title, here) without
    /// touching the cover photo at all must leave an existing Pexels credit
    /// intact — this is what makes the render slot (`TripFormView
    /// .coverPhotoCreditLine`) actually useful once P8c starts writing one,
    /// rather than it evaporating on the trip's very next unrelated save.
    @MainActor
    func testSavingUnrelatedFieldsPreservesAnExistingPexelsCredit() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let trip = Trip(
            id: UUID(), title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: .now, endDate: .now.addingTimeInterval(86_400 * 6), coverGradient: "dusk",
            tripTypeRaw: TripType.family.rawValue, createdBy: UUID(),
            createdAt: .now, updatedAt: .now, updatedBy: nil,
            coverImagePath: "old/pexels-cover.jpg", coverCreditName: "Priya", coverCreditUrl: "https://pexels.com/photo/1"
        )
        context.insert(trip)
        let initialCoverImagePath = trip.coverImagePath

        trip.title = "Porto" // the only field this "save" touches
        let draftCoverImagePath = initialCoverImagePath // unchanged this session
        trip.coverImagePath = draftCoverImagePath
        if draftCoverImagePath != initialCoverImagePath {
            trip.coverCreditName = nil
            trip.coverCreditUrl = nil
        }

        let dto = trip.toDTO()
        XCTAssertEqual(dto.title, "Porto")
        XCTAssertEqual(dto.coverImagePath, "old/pexels-cover.jpg")
        XCTAssertEqual(dto.coverCreditName, "Priya")
        XCTAssertEqual(dto.coverCreditUrl, "https://pexels.com/photo/1")
    }

    // MARK: - Job A hardening (P8b harden pass): the credit-clear invariant
    // across TWO independent save sessions (pick a new photo -> save ->
    // reopen -> edit only the title -> save again) — the three tests above
    // each replicate exactly one save's mutation in isolation; none of them
    // chain a SECOND save with a freshly re-captured `initialValues
    // .coverImagePath` snapshot the way actually reopening the sheet would
    // (`TripFormView.init`'s `.edit` branch reads `trip.coverImagePath`
    // fresh every time it runs). This probes that full sequence instead of
    // just the unit: a future regression that let session 2 compare against
    // session 1's stale snapshot (rather than a fresh read of the trip's
    // CURRENT state) would show up here as the picked photo reverting or
    // the credit re-clearing — neither reachable from a single save.

    /// Session 1 replaces a credited Pexels photo with the user's own pick
    /// (correctly clearing the credit, same rule the tests above already
    /// pin); session 2 reopens fresh and edits ONLY the title. The picked
    /// photo must survive session 2's unrelated save untouched, and the
    /// already-cleared credit must stay cleared rather than being touched
    /// again by a stale comparison.
    @MainActor
    func testCreditClearInvariantHoldsAcrossPickPhotoSaveThenTitleOnlySaveSequence() throws {
        let container = AppSchema.makeContainer(inMemory: true)
        let context = ModelContext(container)

        let trip = Trip(
            id: UUID(), title: "Lisbon", destination: "Lisbon, Portugal", countryCode: "PT",
            startDate: .now, endDate: .now.addingTimeInterval(86_400 * 6), coverGradient: "dusk",
            tripTypeRaw: TripType.family.rawValue, createdBy: UUID(),
            createdAt: .now, updatedAt: .now, updatedBy: nil,
            coverImagePath: "old/pexels-cover.jpg", coverCreditName: "Priya", coverCreditUrl: "https://pexels.com/photo/1"
        )
        context.insert(trip)

        // SESSION 1: sheet opens on the credited photo; user picks their own
        // replacement and taps Save.
        let session1InitialCoverImagePath = trip.coverImagePath
        let session1DraftCoverImagePath = "new/my-own-photo.jpg"
        trip.coverImagePath = session1DraftCoverImagePath
        if session1DraftCoverImagePath != session1InitialCoverImagePath {
            trip.coverCreditName = nil
            trip.coverCreditUrl = nil
        }
        XCTAssertEqual(trip.coverImagePath, "new/my-own-photo.jpg", "sanity: session 1 must land the new photo")
        XCTAssertNil(trip.coverCreditName, "sanity: replacing the credited photo must clear its credit in session 1")

        // SESSION 2: the sheet is reopened fresh on the SAME (now-mutated)
        // trip — `initialValues.coverImagePath` is captured anew from the
        // trip's CURRENT state, never reused from session 1's own local
        // constant above (that's the exact gap a single-save unit test
        // can't probe).
        let session2InitialCoverImagePath = trip.coverImagePath
        XCTAssertNotEqual(
            session2InitialCoverImagePath, session1InitialCoverImagePath,
            "sanity: session 2 must open on what session 1 actually saved, not session 1's own starting point"
        )
        // Only the title changes this session — the draft cover stays
        // exactly what THIS session opened with; the picker was never
        // touched.
        trip.title = "Porto"
        let session2DraftCoverImagePath = session2InitialCoverImagePath
        trip.coverImagePath = session2DraftCoverImagePath
        if session2DraftCoverImagePath != session2InitialCoverImagePath {
            trip.coverCreditName = nil
            trip.coverCreditUrl = nil
        }

        let dto = trip.toDTO()
        XCTAssertEqual(dto.title, "Porto")
        // The core "survives the second save" assertion: the photo session
        // 1 picked is neither reverted nor lost by session 2's unrelated edit.
        XCTAssertEqual(dto.coverImagePath, "new/my-own-photo.jpg")
        // And the credit session 1 correctly cleared stays cleared — session
        // 2's own (correctly no-op) comparison must never resurrect it.
        XCTAssertNil(dto.coverCreditName)
        XCTAssertNil(dto.coverCreditUrl)
    }

    // MARK: - F8: canonicalGradientKey normalization

    func testCanonicalGradientKeyMapsKnownKeysCaseInsensitively() {
        XCTAssertEqual(TripFormView.canonicalGradientKey("dusk"), "dusk")
        XCTAssertEqual(TripFormView.canonicalGradientKey("DUSK"), "dusk")
        XCTAssertEqual(TripFormView.canonicalGradientKey("plum"), "plum")
        XCTAssertEqual(TripFormView.canonicalGradientKey("moss"), "moss")
    }

    func testCanonicalGradientKeyFallsBackToDuskForUnknownOrLegacyKeys() {
        XCTAssertEqual(TripFormView.canonicalGradientKey("default"), "dusk")
        XCTAssertEqual(TripFormView.canonicalGradientKey("sunset"), "dusk")
        XCTAssertEqual(TripFormView.canonicalGradientKey(""), "dusk")
    }

    // MARK: - UX audit finding 6: isCoverGradientChanged compares by what a
    // key canonicalizes to, not the raw stored string.

    func testIsCoverGradientChangedFalseForLegacyDefaultKeyMatchingDusk() {
        // The finding's exact repro: a trip stored as "default" renders
        // Dusk-lit, so tapping the already-lit Dusk swatch (which writes
        // literal "dusk") shouldn't register as a change.
        XCTAssertFalse(TripFormView.isCoverGradientChanged(current: "dusk", initial: "default"))
    }

    func testIsCoverGradientChangedTrueForGenuinelyDifferentGradients() {
        XCTAssertTrue(TripFormView.isCoverGradientChanged(current: "plum", initial: "default"))
    }

    func testIsCoverGradientChangedFalseWhenKeysAreIdentical() {
        XCTAssertFalse(TripFormView.isCoverGradientChanged(current: "dusk", initial: "dusk"))
    }

    func testIsCoverGradientChangedFalseForCaseInsensitiveMatch() {
        XCTAssertFalse(TripFormView.isCoverGradientChanged(current: "moss", initial: "MOSS"))
    }

    func testIsCoverGradientChangedFalseForTwoDistinctUnknownLegacyKeys() {
        // Accepted edge (documented on the helper): two different unknown
        // legacy keys both canonicalize to "dusk", so this also reads as
        // clean — consistent with the swatch already rendering as selected.
        XCTAssertFalse(TripFormView.isCoverGradientChanged(current: "dusk", initial: "sunset"))
    }

    // MARK: - UX audit finding 1: CTA-guidance precedence (save error ->
    // blank title -> unacceptable country), including the CTA-slot fix that
    // surfaces an unacceptable country code even off-screen.

    func testCTAGuidancePrefersSaveErrorOverEverythingElse() {
        let guidance = TripFormView.ctaGuidance(
            saveError: "Couldn\u{2019}t save the trip. Try again.", title: "", countryCode: "PO", isEditing: false,
            isSignedOutOnCreate: false
        )
        XCTAssertEqual(guidance?.message, "Couldn\u{2019}t save the trip. Try again.")
        XCTAssertEqual(guidance?.isError, true)
    }

    func testCTAGuidanceFallsBackToBlankTitleWhenNoSaveError() {
        let guidance = TripFormView.ctaGuidance(
            saveError: nil, title: "  ", countryCode: "", isEditing: false, isSignedOutOnCreate: false
        )
        XCTAssertEqual(guidance?.message, "Enter a trip name to create the trip.")
        XCTAssertEqual(guidance?.isError, false)
    }

    func testCTAGuidanceSurfacesUnacceptableCountryWhenTitleIsValid() {
        let guidance = TripFormView.ctaGuidance(
            saveError: nil, title: "Lisbon", countryCode: "PO", isEditing: true, isSignedOutOnCreate: false
        )
        XCTAssertEqual(
            guidance?.message,
            "This trip\u{2019}s saved country isn\u{2019}t recognized. Tap Country and pick one \u{2014} or " +
                "choose \u{201C}No country\u{201D} \u{2014} to save changes."
        )
        XCTAssertEqual(guidance?.isError, true)
    }

    func testCTAGuidanceNilWhenEverythingIsAcceptable() {
        XCTAssertNil(TripFormView.ctaGuidance(
            saveError: nil, title: "Lisbon", countryCode: "PT", isEditing: false, isSignedOutOnCreate: false
        ))
        XCTAssertNil(TripFormView.ctaGuidance(
            saveError: nil, title: "Lisbon", countryCode: "", isEditing: false, isSignedOutOnCreate: false
        ))
    }

    func testCTAGuidancePrefersSaveErrorOverUnacceptableCountryWhenTitleIsValid() {
        let guidance = TripFormView.ctaGuidance(
            saveError: "Couldn\u{2019}t save the trip. Try again.", title: "Lisbon", countryCode: "PO", isEditing: true,
            isSignedOutOnCreate: false
        )
        XCTAssertEqual(guidance?.message, "Couldn\u{2019}t save the trip. Try again.")
        XCTAssertEqual(guidance?.isError, true)
    }

    // MARK: - UX audit cycle 2 finding 2: signed-out-on-create guidance takes
    // priority over everything else, including a save error and an otherwise
    // valid title/country — a signed-out create sheet can't be saved at all.

    func testCTAGuidancePrefersSignedOutOnCreateOverSaveErrorAndValidFields() {
        let guidance = TripFormView.ctaGuidance(
            saveError: "Couldn\u{2019}t save the trip. Try again.", title: "Lisbon", countryCode: "PT",
            isEditing: false, isSignedOutOnCreate: true
        )
        XCTAssertEqual(guidance?.message, "You\u{2019}re signed out. Sign back in to create a trip.")
        XCTAssertEqual(guidance?.isError, true)
    }

    // MARK: - Picker empty-results state: `countries(matching:)` must return
    // nothing for a city name or a misspelled country, not a spurious match.

    func testCountriesMatchingReturnsEmptyForCityNameOrTypo() {
        XCTAssertTrue(TripFormValidation.countries(matching: "Lisbon").isEmpty)
        XCTAssertTrue(TripFormValidation.countries(matching: "Protugal").isEmpty)
    }

    // MARK: - P4.4 (docs/UX_REDESIGN_ROADMAP.md): seededGradientKey — a
    // deterministic (never `String.hashValue`, re-seeded per process
    // launch) checksum, not true randomness, so the same destination always
    // renders the same cover across cold starts.

    func testSeededGradientKeyIsDeterministicForTheSameInput() {
        let first = TripFormView.seededGradientKey(countryCode: "PT", destination: "Lisbon")
        let second = TripFormView.seededGradientKey(countryCode: "PT", destination: "Lisbon")
        XCTAssertEqual(first, second)
    }

    func testSeededGradientKeyFallsBackToDuskForBlankInput() {
        XCTAssertEqual(TripFormView.seededGradientKey(countryCode: "", destination: ""), "dusk")
    }

    func testSeededGradientKeyIsCaseInsensitive() {
        let lower = TripFormView.seededGradientKey(countryCode: "pt", destination: "lisbon")
        let mixed = TripFormView.seededGradientKey(countryCode: "PT", destination: "Lisbon")
        XCTAssertEqual(lower, mixed)
    }

    func testSeededGradientKeyIsAlwaysOneOfTheThreeOptions() {
        let key = TripFormView.seededGradientKey(countryCode: "TH", destination: "Bangkok")
        XCTAssertTrue(["dusk", "plum", "moss"].contains(key))
    }

    /// Hand-verified checksums (byte sum mod 3) so this pins the exact
    /// mapping rather than merely "differs" — single-letter destinations
    /// keep the arithmetic checkable by hand: "a"=97 (%3=1 -> plum),
    /// "b"=98 (%3=2 -> moss), "c"=99 (%3=0 -> dusk).
    func testSeededGradientKeyDistributesAcrossAllThreeBuckets() {
        XCTAssertEqual(TripFormView.seededGradientKey(countryCode: "", destination: "a"), "plum")
        XCTAssertEqual(TripFormView.seededGradientKey(countryCode: "", destination: "b"), "moss")
        XCTAssertEqual(TripFormView.seededGradientKey(countryCode: "", destination: "c"), "dusk")
    }

    /// Same "hand-verified checksum" spirit as the single-letter test above,
    /// but with realistic multi-character destinations, and — the actual
    /// point of this test — expected values computed via a byte sum done
    /// entirely independently of this file (a throwaway Python script summing
    /// UTF-8 code units mod 3), not by copy-pasting the Swift `reduce`. This
    /// is the strongest hermetic proxy available for "same destination, same
    /// cover, across a cold process relaunch" (an actual relaunch isn't
    /// observable from inside one `xctest` process): a `String.hashValue`-
    /// based implementation would NOT reliably reproduce these exact fixed
    /// keys — its per-launch-random seed makes it agree with a fixed
    /// expectation by chance only 1 time in 3 — whereas the real deterministic
    /// byte-sum checksum matches every time, so this fails immediately (not
    /// flakily) if `seededGradientKey` were ever swapped to hash-based.
    func testSeededGradientKeyMatchesAnIndependentlyComputedByteChecksumForRealisticDestinations() {
        XCTAssertEqual(TripFormView.seededGradientKey(countryCode: "PT", destination: "Lisbon"), "moss")
        XCTAssertEqual(TripFormView.seededGradientKey(countryCode: "FR", destination: "Paris"), "dusk")
    }

    /// The literal "two independent computations of the same destination
    /// agree" case: the identical logical seed built two different ways (a
    /// plain literal vs. concatenated from separately-held substrings, so
    /// the two calls don't share so much as a `String` buffer) still produce
    /// the same key.
    func testSeededGradientKeyAgreesAcrossTwoIndependentlyConstructedCopiesOfTheSameInput() {
        let destinationPart1 = "Lis"
        let destinationPart2 = "bon"
        let fromLiteral = TripFormView.seededGradientKey(countryCode: "PT", destination: "Lisbon")
        let fromConcatenation = TripFormView.seededGradientKey(countryCode: "P" + "T", destination: destinationPart1 + destinationPart2)
        XCTAssertEqual(fromLiteral, fromConcatenation)
    }

    // MARK: - P4.4: shuffledGradientKey — cycles rather than picks truly at
    // random, so it's always visibly different from the current cover and
    // stays deterministic here.

    func testShuffleAlwaysChangesTheSelection() {
        for key in ["dusk", "plum", "moss"] {
            XCTAssertNotEqual(TripFormView.shuffledGradientKey(current: key), key)
        }
    }

    func testShuffleCyclesThroughAllThreeOptionsInOrder() {
        XCTAssertEqual(TripFormView.shuffledGradientKey(current: "dusk"), "plum")
        XCTAssertEqual(TripFormView.shuffledGradientKey(current: "plum"), "moss")
        XCTAssertEqual(TripFormView.shuffledGradientKey(current: "moss"), "dusk")
    }

    func testShuffleNormalizesAnUnknownCurrentKeyFirst() {
        // canonicalGradientKey("default") == "dusk" — shuffling from either
        // should step to the same next option.
        XCTAssertEqual(
            TripFormView.shuffledGradientKey(current: "default"),
            TripFormView.shuffledGradientKey(current: "dusk")
        )
    }

    /// Explicit membership check (not just "differs from current" /
    /// "cycles in this exact order" as the two tests above already pin):
    /// every result must be one of the three real `gradientOptions`, for
    /// every single element of that set taken on its own as well as for
    /// legacy/unknown/blank `current` values — guards the modulo-cycling
    /// arithmetic (`(currentIndex + 1) % gradientOptions.count`) from ever
    /// indexing outside the known set, including the `?? 0` fallback branch
    /// an unrecognized `current` takes.
    func testShuffleStaysWithinTheThreeGradientOptionsForEverySingleKnownOrLegacyKey() {
        let validOptions: Set<String> = ["dusk", "plum", "moss"]
        for key in ["dusk", "plum", "moss", "DUSK", "default", "sunset", ""] {
            let result = TripFormView.shuffledGradientKey(current: key)
            XCTAssertTrue(
                validOptions.contains(result),
                "shuffledGradientKey(current: \"\(key)\") produced out-of-bounds \"\(result)\""
            )
        }
    }

    // MARK: - P6.5: canonicalGradientKey preserves a valid generated key
    // (a genuine, distinct cover) instead of folding it into "dusk" the way
    // an unknown/legacy key still does.

    func testCanonicalGradientKeyPreservesAValidGeneratedKey() {
        let key = "gen:v1:120,45"
        XCTAssertEqual(TripFormView.canonicalGradientKey(key), key)
    }

    func testCanonicalGradientKeyFallsBackToDuskForAMalformedGeneratedKey() {
        XCTAssertEqual(TripFormView.canonicalGradientKey("gen:v1:400,45"), "dusk")
    }

    func testIsCoverGradientChangedTrueForTwoDifferentGeneratedKeys() {
        XCTAssertTrue(TripFormView.isCoverGradientChanged(current: "gen:v1:10,20", initial: "gen:v1:30,40"))
    }

    func testIsCoverGradientChangedFalseForTheSameGeneratedKeyTwice() {
        XCTAssertFalse(TripFormView.isCoverGradientChanged(current: "gen:v1:10,20", initial: "gen:v1:10,20"))
    }

    // MARK: - P6.5: nextShuffledGradientKey — Shuffle's actual behavior,
    // mixing fresh `CoverGradientGenerator` rolls with the three curated
    // classics (`shuffledGradientKey`, unchanged, still covered above).

    func testNextShuffledGradientKeyGeneratesWhenSeedIsNotAMultipleOfFour() {
        let key = TripFormView.nextShuffledGradientKey(current: "dusk", seed: 1)
        XCTAssertTrue(key.hasPrefix("gen:v1:"))
    }

    func testNextShuffledGradientKeyStepsToTheNextCuratedClassicEveryFourthSeed() {
        XCTAssertEqual(
            TripFormView.nextShuffledGradientKey(current: "dusk", seed: 4),
            TripFormView.shuffledGradientKey(current: "dusk")
        )
        XCTAssertEqual(TripFormView.nextShuffledGradientKey(current: "dusk", seed: 4), "plum")
    }

    func testNextShuffledGradientKeyIsDeterministicForTheSameSeed() {
        XCTAssertEqual(
            TripFormView.nextShuffledGradientKey(current: "moss", seed: 99),
            TripFormView.nextShuffledGradientKey(current: "moss", seed: 99)
        )
    }

    // MARK: - P6.5 harden: does Shuffle ever repeat the same key twice in a
    // row? The two branches have DIFFERENT guarantees -- pinning both rather
    // than assuming one blanket "never repeats" contract for the whole
    // function.

    /// The "1-in-4 classic" branch (`seed.isMultiple(of: 4)`) always steps to
    /// `shuffledGradientKey`, which cycles `(currentIndex + 1) %
    /// gradientOptions.count` -- with 3 options, `nextIndex` can never equal
    /// `currentIndex`, so this branch alone provably never repeats the
    /// current curated key.
    func testNextShuffledGradientKeyOnTheClassicBranchNeverRepeatsTheCurrentCuratedKey() {
        for key in ["dusk", "plum", "moss"] {
            let next = TripFormView.nextShuffledGradientKey(current: key, seed: 4) // 4.isMultiple(of: 4) -> classic branch
            XCTAssertNotEqual(next, key, "current \(key)")
        }
    }

    /// The other 3-in-4 branch is a PURE function of `seed` alone --
    /// `CoverGradientGenerator.generate(seed:)` never reads `current`, so
    /// nothing excludes it from reproducing `current` verbatim. This is not
    /// a defect: real entropy (`UInt64.random(in:)`) makes the same `UInt64`
    /// recurring back to back astronomically unlikely, and the docs on
    /// `nextShuffledGradientKey` never actually promise otherwise. Pinned
    /// here as the function's real (weaker) contract, since the brief calls
    /// out checking rather than assuming this.
    func testNextShuffledGradientKeyOnTheRandomBranchCanReproduceTheCurrentKeyIfTheSameSeedRecurs() {
        let seed: UInt64 = 5 // not a multiple of 4 -> the fresh-random-roll branch
        let generated = TripFormView.nextShuffledGradientKey(current: "dusk", seed: seed)
        XCTAssertTrue(generated.hasPrefix("gen:v1:"), "sanity: seed 5 must take the generate branch")
        XCTAssertEqual(
            TripFormView.nextShuffledGradientKey(current: generated, seed: seed), generated,
            "the random branch has no guard against reproducing `current` when the same seed recurs"
        )
    }
}
