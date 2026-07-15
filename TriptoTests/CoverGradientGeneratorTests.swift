import UIKit
import XCTest
@testable import Tripto

/// UX P6.5 (`.claude/company/ux-redesign/DECISIONS.md` 2026-07-15):
/// `CoverGradientGenerator` — the `"gen:v1:<hue1>,<hue2>"` seeded generator
/// `CoverGradient.from(key:)` (Tokens.swift, generated) falls back to for
/// any key that isn't one of the three curated names. Covers determinism,
/// the encode/decode round-trip, malformed-key fallback (mirroring P4's own
/// legacy-key test pattern in `TripFormViewTests`), and the brightness cap
/// that keeps the existing text-scrim/pill contrast audit valid for a
/// generated gradient too.
final class CoverGradientGeneratorTests: XCTestCase {
    // MARK: - generate(seed:) determinism

    func testGenerateIsDeterministicForTheSameSeed() {
        XCTAssertEqual(CoverGradientGenerator.generate(seed: 42), CoverGradientGenerator.generate(seed: 42))
    }

    func testGenerateProducesDifferentKeysForDifferentSeeds() {
        XCTAssertNotEqual(CoverGradientGenerator.generate(seed: 1), CoverGradientGenerator.generate(seed: 2))
    }

    func testGenerateProducesTheVersionedPrefix() {
        XCTAssertTrue(CoverGradientGenerator.generate(seed: 7).hasPrefix("gen:v1:"))
    }

    // MARK: - encode/decode round-trip

    func testParsedHuesRecoversExactlyWhatGenerateEncoded() {
        let seed: UInt64 = 12_345
        let key = CoverGradientGenerator.generate(seed: seed)
        let hues = CoverGradientGenerator.parsedHues(key)
        XCTAssertEqual(hues?.0, Int(seed % 360))
        XCTAssertEqual(hues?.1, Int((seed / 360) % 360))
    }

    func testDecodeSucceedsForEveryGeneratedKey() {
        let seeds: [UInt64] = [0, 1, 42, 359, 360, 999_999]
        for seed in seeds {
            XCTAssertNotNil(CoverGradientGenerator.decode(CoverGradientGenerator.generate(seed: seed)), "seed \(seed)")
        }
    }

    func testParsedHuesIsCaseInsensitive() {
        XCTAssertEqual(CoverGradientGenerator.parsedHues("GEN:V1:10,20")?.0, 10)
        XCTAssertEqual(CoverGradientGenerator.parsedHues("GEN:V1:10,20")?.1, 20)
    }

    // MARK: - malformed keys fall back (decode -> nil, same contract
    // `CoverGradient.from(key:)` already has for an unrecognized curated
    // key — extends P4's legacy-key test pattern to this new key shape).

    func testDecodeReturnsNilForNilKey() {
        XCTAssertNil(CoverGradientGenerator.decode(nil))
    }

    func testDecodeReturnsNilForKeysWithNoGenPrefix() {
        XCTAssertNil(CoverGradientGenerator.decode("garbage"))
        XCTAssertNil(CoverGradientGenerator.decode(""))
    }

    func testDecodeReturnsNilForAWrongVersionPrefix() {
        // Versioned on purpose (doc comment on `CoverGradientGenerator`) —
        // a future v2 format must not be silently misread as v1.
        XCTAssertNil(CoverGradientGenerator.decode("gen:v2:10,20"))
    }

    func testDecodeReturnsNilForTheWrongNumberOfParts() {
        XCTAssertNil(CoverGradientGenerator.decode("gen:v1:10"))
        XCTAssertNil(CoverGradientGenerator.decode("gen:v1:10,20,30"))
    }

    func testDecodeReturnsNilForNonNumericParts() {
        XCTAssertNil(CoverGradientGenerator.decode("gen:v1:abc,20"))
    }

    func testDecodeReturnsNilForOutOfRangeHues() {
        XCTAssertNil(CoverGradientGenerator.decode("gen:v1:360,20"))
        XCTAssertNil(CoverGradientGenerator.decode("gen:v1:10,-1"))
    }

    /// No namespace collision with the existing curated/legacy keys —
    /// `CoverGradient.from(key:)` never even reaches the generator for
    /// these (its `switch` matches them first), and calling the generator
    /// directly on one is still a clean, documented "not mine" rather than
    /// an accidental partial match. This is the P4-style regression
    /// guarantee that existing trips' covers render unchanged.
    func testDecodeReturnsNilForEveryExistingCuratedOrLegacyKey() {
        for key in ["dusk", "plum", "moss", "default", "sunset", ""] {
            XCTAssertNil(CoverGradientGenerator.decode(key), key)
        }
    }

    func testCuratedKeysNeverParseAsGeneratorHues() {
        for key in ["dusk", "plum", "moss", "default"] {
            XCTAssertNil(CoverGradientGenerator.parsedHues(key), key)
        }
    }

    // MARK: - brightness cap (P6.5 brief: "avoid generating near-white
    // tops... cap brightness so the scrim math holds").

    /// t=1 (hue 359, the brightest end of the band) hits the documented
    /// ceiling exactly: 91% is dusk's own accent stop (`#E8955A`) — the
    /// brightest stop across the curated set AND the exact "lightest stop"
    /// `PaletteExtras.coverPillFill`'s own contrast math already treats as
    /// its worst case. `lerp` is linear, so the two endpoints (here and
    /// the `t=0` case below) already bound every value in between.
    func testStop1BrightnessCapMatchesTheDocumentedCeilingOf91Percent() {
        XCTAssertEqual(CoverGradientGenerator.lerp(CoverGradientGenerator.stop1Brightness, 1.0), 0.91, accuracy: 0.0001)
    }

    func testStop1BrightnessLowerBoundIs62Percent() {
        XCTAssertEqual(CoverGradientGenerator.lerp(CoverGradientGenerator.stop1Brightness, 0.0), 0.62, accuracy: 0.0001)
    }

    /// 79% — dusk's own stop2 brightness, the curated set's max there.
    func testStop2BrightnessCapMatchesTheDocumentedCeilingOf79Percent() {
        XCTAssertEqual(CoverGradientGenerator.lerp(CoverGradientGenerator.stop2Brightness, 1.0), 0.79, accuracy: 0.0001)
    }

    /// End-to-end check (not just the pure `lerp` arithmetic above): the
    /// actual rendered `Color` at the brightest possible hue, read back via
    /// `UIColor`, never exceeds the cap — catches a mistake in how
    /// `stopColor` wires `brightness` into `Color(hue:saturation:
    /// brightness:)` that a `lerp`-only test wouldn't.
    func testStop1ColorAtItsBrightestHueNeverExceedsTheBrightnessCap() {
        let color = CoverGradientGenerator.stopColor(
            hue: 359, saturation: CoverGradientGenerator.stop1Saturation, brightness: CoverGradientGenerator.stop1Brightness
        )
        var brightness: CGFloat = 0
        UIColor(color).getHue(nil, saturation: nil, brightness: &brightness, alpha: nil)
        XCTAssertLessThanOrEqual(brightness, 0.91 + 0.01)
    }

    // MARK: - Locale invariance (P6.5 harden brief: the key format must not
    // depend on `Locale.current`) -- unlike `Double`/`NumberFormatter`,
    // Swift's plain `Int(String)` parse and `Int` string interpolation never
    // consult locale, so there's no live decimal-comma/grouping/digit-script
    // risk here as long as `generate`/`parsedHues` stay built on plain `Int`,
    // never a `Double` or `NumberFormatter` detour. This pins that structural
    // guarantee directly against the key text rather than trying to
    // force-swap the process's ambient `Locale.current` (not reliably
    // possible from inside a running XCTest without a relaunch) -- German
    // (`de_DE`, the brief's own "non-dot-decimal" example) is exactly the
    // comma-as-decimal-separator locale this would catch if a future change
    // ever routed a hue through locale-aware formatting.

    func testGeneratedKeyBodyIsAlwaysPlainASCIIDigitsAndCommaAcrossManySeeds() {
        let seeds: [UInt64] = [0, 1, 42, 200, 359, 360, 999_999, .max]
        for seed in seeds {
            let key = CoverGradientGenerator.generate(seed: seed)
            let body = key.dropFirst(CoverGradientGenerator.prefix.count)
            XCTAssertTrue(
                !body.isEmpty && body.allSatisfy { $0 == "," || ("0"..."9").contains($0) },
                "seed \(seed) produced a key with non-ASCII-digit characters: \(key)"
            )
        }
    }

    /// The brief's own example locale (`de_DE` -- comma as the DECIMAL
    /// separator, `.` as the thousands separator): formatting these same hue
    /// integers through an actual German `NumberFormatter` produces
    /// byte-identical text to the plain digits already in the key at this
    /// magnitude (0...359 never reaches a thousands grouping, and German
    /// still uses Latin digits) -- so no locale can currently make this
    /// format render differently, which is what makes today's bare
    /// `Int`/`String` implementation already locale-safe.
    func testHueIntegersFormatIdenticallyUnderAGermanLocale() {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "de_DE")
        for hue in [0, 9, 42, 200, 359] {
            XCTAssertEqual(formatter.string(from: NSNumber(value: hue)), String(hue), "hue \(hue)")
        }
    }

    // MARK: - Hostile keys from another device/app version (P6.5 harden
    // brief): every one of these must fall back (`decode` -> `nil`,
    // `CoverGradient.from(key:)` -> the default gradient) rather than crash --
    // values another (older/newer, or hand-edited) client could plausibly
    // have written to the shared `Trip.cover_gradient` column.

    func testDecodeNeverCrashesAndAlwaysFallsBackForHostileKeysFromAnotherDevice() {
        let hostileKeys = [
            "gen:v1:999,-5", // both hues out of the documented 0...359 range
            "gen:v1:", // empty body -- no comma, no hues at all
            "gen:v1:NaN,12", // non-numeric first hue
            "gen:v2:10,20", // a future/foreign version -- must not be misread as v1
            "gen:v1:10,20,30,40" // extra stops
        ]
        for key in hostileKeys {
            XCTAssertNil(CoverGradientGenerator.decode(key), key)
            // `CoverGradient.from(key:)` is the one seam every render site
            // actually goes through -- proving it completes (doesn't trap)
            // for every hostile key is the real "never crashes" guarantee;
            // reaching the assertion above for the NEXT key in this loop is
            // itself proof this call didn't crash the process.
            _ = CoverGradient.from(key: key)
        }
    }

    // MARK: - Property sweep (P6.5 harden brief: "500-roll"): every generated
    // key round-trips exactly and every decoded stop sits inside the
    // documented S/V bands, across many rolls -- not just the hand-picked
    // seeds above. Seeds are a deterministic spread (a fixed multiplicative
    // step across `UInt64`), not `UInt64.random`, so a failure is
    // reproducible from the printed seed alone and this suite never gains a
    // flaky, non-deterministic test -- the same "no hidden randomness"
    // discipline `TripFormViewTests`' own `seededGradientKey` tests already
    // document a preference for.
    func testFiveHundredRollsRoundTripExactlyAndStayWithinTheDocumentedBands() {
        for i in 0..<500 {
            let seed = UInt64(i) &* 2_654_435_761 // Knuth multiplicative spread
            let key = CoverGradientGenerator.generate(seed: seed)
            let hues = CoverGradientGenerator.parsedHues(key)
            XCTAssertEqual(hues?.0, Int(seed % 360), "seed \(seed)")
            XCTAssertEqual(hues?.1, Int((seed / 360) % 360), "seed \(seed)")
            guard let (hue1, hue2) = hues else { continue }
            XCTAssertNotNil(CoverGradientGenerator.decode(key), "seed \(seed)")

            assertStopWithinBands(
                hue: hue1, saturation: CoverGradientGenerator.stop1Saturation,
                brightness: CoverGradientGenerator.stop1Brightness, seed: seed
            )
            assertStopWithinBands(
                hue: hue2, saturation: CoverGradientGenerator.stop2Saturation,
                brightness: CoverGradientGenerator.stop2Brightness, seed: seed
            )
        }
    }

    /// Reads a `stopColor(...)` result back via `UIColor` (same technique as
    /// `testStop1ColorAtItsBrightestHueNeverExceedsTheBrightnessCap` above)
    /// and checks both saturation and brightness sit inside the given band,
    /// with the same `0.01` float slack that existing test already uses for
    /// an HSB round trip.
    private func assertStopWithinBands(
        hue: Int, saturation: ClosedRange<Double>, brightness: ClosedRange<Double>, seed: UInt64,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let color = CoverGradientGenerator.stopColor(hue: hue, saturation: saturation, brightness: brightness)
        var actualSaturation: CGFloat = 0
        var actualBrightness: CGFloat = 0
        UIColor(color).getHue(nil, saturation: &actualSaturation, brightness: &actualBrightness, alpha: nil)
        XCTAssertTrue(
            actualSaturation >= saturation.lowerBound - 0.01 && actualSaturation <= saturation.upperBound + 0.01,
            "seed \(seed) hue \(hue): saturation \(actualSaturation) outside \(saturation)", file: file, line: line
        )
        XCTAssertTrue(
            actualBrightness >= brightness.lowerBound - 0.01 && actualBrightness <= brightness.upperBound + 0.01,
            "seed \(seed) hue \(hue): brightness \(actualBrightness) outside \(brightness)", file: file, line: line
        )
    }
}
