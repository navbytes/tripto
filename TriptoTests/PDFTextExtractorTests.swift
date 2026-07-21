import PDFKit
import UIKit
import XCTest
@testable import Tripto

/// C3 (`.claude/company/release-1.2/PLAN.md`): `PDFTextExtractor`'s two
/// branches (PDFKit text-layer first, scanned-page OCR fallback) plus the
/// size cap. Fully hermetic: every PDF here is built in-process via
/// `UIGraphicsPDFRenderer` — no bundled fixture files, no network.
final class PDFTextExtractorTests: XCTestCase {
    /// `NSString.draw(at:withAttributes:)` into a `UIGraphicsPDFRenderer`
    /// context embeds REAL, selectable text (CoreText writes glyph→Unicode
    /// mapping into the PDF content stream) — this is what makes
    /// `PDFPage.string` non-empty and routes `extractText` through the
    /// text-layer branch, never touching OCR at all.
    private func makeTextLayerPDF(_ text: String) -> Data {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 200)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            context.beginPage()
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 24)]
            (text as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: attributes)
        }
    }

    /// Draws the SAME text as a rasterized `UIImage` (via the same recipe
    /// `OCRServiceTests` uses) instead of real glyphs — `PDFPage.string`
    /// reads back empty/near-empty for a page like this (no text layer, only
    /// an embedded bitmap), exactly like a photographed/scanned document, so
    /// `extractText` must fall through to rendering the page and OCR-ing it.
    private func makeScannedPDF(_ text: String) -> Data {
        let pageSize = CGSize(width: 612, height: 200)
        let imageFormat = UIGraphicsImageRendererFormat()
        imageFormat.scale = 1
        let textImage = UIGraphicsImageRenderer(size: pageSize, format: imageFormat).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: pageSize))
            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 40, weight: .bold), .foregroundColor: UIColor.black
            ]
            (text as NSString).draw(at: CGPoint(x: 20, y: 60), withAttributes: attributes)
        }

        let bounds = CGRect(origin: .zero, size: pageSize)
        let renderer = UIGraphicsPDFRenderer(bounds: bounds)
        return renderer.pdfData { context in
            context.beginPage()
            textImage.draw(at: .zero)
        }
    }

    func testExtractsTextLayerDirectlyFromARealPDF() async throws {
        let source = "TAP Air Portugal TP1234 confirmation ABC123"
        let pdf = makeTextLayerPDF(source)
        let text = try await PDFTextExtractor.extractText(from: pdf)
        // Whitespace-insensitive compare: `PDFPage.string` reconstructs word
        // boundaries from glyph gaps in the content stream (a documented
        // PDFKit quirk, independent of this extractor's own code) and can
        // occasionally insert a stray space mid-word for synthetically-drawn
        // text — stripping whitespace on both sides pins that every
        // CHARACTER of the text layer came through, without depending on
        // PDFKit's own spacing heuristic being byte-exact (never a contract
        // `PDFTextExtractor` needs: its output feeds an LLM prompt, not
        // something spacing-sensitive).
        let stripWhitespace: (String) -> String = { $0.filter { !$0.isWhitespace } }
        XCTAssertEqual(stripWhitespace(text), stripWhitespace(source), "expected the PDF's own text layer to come back, got: \(text)")
    }

    /// The scanned branch is a full round trip through `OCRService` too —
    /// this is the one test that actually proves the "render page → OCR"
    /// fallback wiring, not just that OCR itself works (`OCRServiceTests`
    /// already covers that in isolation).
    func testFallsBackToOCRForAScannedPageWithNoTextLayer() async throws {
        let pdf = makeScannedPDF("SCANNED BOOKING")
        let text = try await PDFTextExtractor.extractText(from: pdf)
        XCTAssertTrue(text.uppercased().contains("SCANNED BOOKING"), "expected OCR to read the rasterized page, got: \(text)")
    }

    func testRejectsFilesOverTenMegabytes() async {
        let oversized = Data(repeating: 0, count: PDFTextExtractor.maxBytes + 1)
        do {
            _ = try await PDFTextExtractor.extractText(from: oversized)
            XCTFail("expected .tooLarge to be thrown")
        } catch let error as PDFTextExtractor.PDFError {
            guard case .tooLarge = error else { return XCTFail("expected .tooLarge, got \(error)") }
            XCTAssertEqual(error.errorDescription, "That PDF is too large to import (10 MB max).")
        } catch {
            XCTFail("expected a PDFTextExtractor.PDFError, got \(error)")
        }
    }

    /// A file exactly AT the cap passes the SIZE guard — only strictly-over
    /// rejects, mirroring the attachments vertical's own inclusive
    /// `byte_size` bound (PLAN.md C1: `between 1 and 10485760`). Uses
    /// garbage (non-PDF) bytes rather than a byte-exact real PDF: padding a
    /// real PDF out to an exact size risks corrupting its trailing
    /// xref/`%%EOF` structure, which most parsers expect to find within a
    /// fixed window of the TRUE end of file. Garbage bytes still prove the
    /// boundary: `.tooLarge` would mean the size guard rejected it before
    /// ever reaching `PDFDocument(data:)`; `.unreadable` proves it got PAST
    /// the size guard and failed for the real reason (not a parseable PDF).
    func testSizeCapIsInclusiveNotExclusive() async {
        let atCap = Data(repeating: 0, count: PDFTextExtractor.maxBytes)
        do {
            _ = try await PDFTextExtractor.extractText(from: atCap)
            XCTFail("expected .unreadable (garbage bytes, not a real PDF)")
        } catch let error as PDFTextExtractor.PDFError {
            guard case .unreadable = error else { return XCTFail("expected .unreadable (proving the size gate passed), got \(error)") }
        } catch {
            XCTFail("expected a PDFTextExtractor.PDFError, got \(error)")
        }
    }

    func testUnreadableDataThrowsAFriendlyError() async {
        let garbage = Data("not a pdf".utf8)
        do {
            _ = try await PDFTextExtractor.extractText(from: garbage)
            XCTFail("expected .unreadable to be thrown")
        } catch let error as PDFTextExtractor.PDFError {
            guard case .unreadable = error else { return XCTFail("expected .unreadable, got \(error)") }
        } catch {
            XCTFail("expected a PDFTextExtractor.PDFError, got \(error)")
        }
    }
}
