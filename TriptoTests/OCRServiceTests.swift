import UIKit
import XCTest
@testable import Tripto

/// C3 (`.claude/company/release-1.2/PLAN.md`): `OCRService`'s round-trip —
/// render known text into a `UIImage` with `UIGraphicsImageRenderer`, OCR
/// it back, assert the content survives. Hermetic (no network, no live
/// model) but NOT fully OS-tier-independent: this suite always runs against
/// whatever iOS the test simulator boots (this repo's CI/dev target is
/// iPhone 17 Pro on iOS 26.5), so it always exercises
/// `RecognizeDocumentsRequest` (`OCRService.extractWithDocumentRecognition`)
/// — the `VNRecognizeTextRequest` legacy tier (iOS 17–25) has no separate
/// coverage here. That tier's exact API surface was instead verified
/// directly against the SDK headers at authoring time (see
/// `OCRService.swift`'s own doc comment); every assertion below is
/// content-based (what text comes back), not tier-specific, so it would
/// pass identically on either tier if this suite ever ran on an
/// iOS 17–25 simulator.
final class OCRServiceTests: XCTestCase {
    /// Large, high-contrast black-on-white text — Vision's recognizers are
    /// tuned for real-world photos/scans, not tiny hairline glyphs, so a
    /// generously-sized render is what makes this reliable in CI rather than
    /// flaky.
    private func renderTextImage(_ lines: [String], size: CGSize = CGSize(width: 900, height: 400)) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1 // deterministic pixel size regardless of host screen scale
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        return renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 56, weight: .bold),
                .foregroundColor: UIColor.black
            ]
            for (index, line) in lines.enumerated() {
                (line as NSString).draw(at: CGPoint(x: 24, y: 24 + CGFloat(index) * 120), withAttributes: attributes)
            }
        }
    }

    func testExtractsKnownTextFromARenderedImage() async throws {
        let image = renderTextImage(["HELLO TRIPTO"])
        let result = try await OCRService.extractText(from: image)
        let uppercased = result.uppercased()
        XCTAssertTrue(
            uppercased.contains("HELLO") && uppercased.contains("TRIPTO"),
            "expected to read back the rendered text, got: \(result)"
        )
    }

    /// C3: "empty result is not a thrown error" — a blank photo has nothing
    /// to recognize; `PasteImportSheet`'s batch loop is the one that turns
    /// this into the friendly "couldn't read this image" row, so the
    /// service itself must return "", not throw.
    func testBlankImageProducesEmptyStringNotAThrow() async throws {
        let blank = renderTextImage([])
        let result = try await OCRService.extractText(from: blank)
        XCTAssertTrue(result.isEmpty, "a blank image has nothing to recognize — empty, not an error")
    }

    /// Reading order preserved across multiple lines (C3: "joined plain text
    /// preserving reading order/line breaks") — both lines must be present,
    /// with the first line's text appearing before the second's.
    func testPreservesMultiLineReadingOrder() async throws {
        let image = renderTextImage(["FIRST LINE", "SECOND LINE"])
        let result = try await OCRService.extractText(from: image)
        let uppercased = result.uppercased()
        guard
            let firstRange = uppercased.range(of: "FIRST LINE"),
            let secondRange = uppercased.range(of: "SECOND LINE")
        else {
            return XCTFail("expected both lines recognized, got: \(result)")
        }
        XCTAssertTrue(firstRange.upperBound <= secondRange.lowerBound, "FIRST LINE must read before SECOND LINE")
    }

    /// The `CGImage` overload assumes `.up`; the `UIImage` overload derives
    /// orientation from `imageOrientation` instead — for an image with no
    /// rotation (the common case: a renderer-produced `UIImage` defaults to
    /// `.up`), both entry points must agree.
    func testCGImageAndUIImageOverloadsAgreeForAnUprightImage() async throws {
        let image = renderTextImage(["AGREEMENT"])
        guard let cgImage = image.cgImage else { return XCTFail("renderer always produces a backing CGImage") }
        XCTAssertEqual(image.imageOrientation, .up, "precondition: a renderer-produced UIImage has no rotation")
        let viaCGImage = try await OCRService.extractText(from: cgImage)
        let viaUIImage = try await OCRService.extractText(from: image)
        XCTAssertEqual(viaCGImage, viaUIImage)
    }

    /// `UIImage(cgImage:)` with no backing `Data`/decoder still has SOME
    /// `cgImage`, so the realistic failure this guards is documented rather
    /// than exercised (a `UIImage` truly without a `cgImage` — e.g. one
    /// backed only by a `CIImage` — is not constructible via the renderer
    /// this suite otherwise uses) — kept as a named, if currently
    /// unreachable-in-this-suite, contract: `OCRError.invalidImage`.
    func testOCRErrorInvalidImageHasAFriendlyDescription() {
        XCTAssertEqual(OCRService.OCRError.invalidImage.errorDescription, "That doesn\u{2019}t look like a readable image.")
    }
}
