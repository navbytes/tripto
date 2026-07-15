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
}
