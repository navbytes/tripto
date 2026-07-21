import PDFKit
import UIKit

// C3 (`.claude/company/release-1.2/PLAN.md`): scan-to-add's PDF tier.
// PDFKit's own text layer first (a "real" PDF, e.g. an airline's emailed
// confirmation saved as PDF, already carries selectable text — no OCR
// needed, and it's both faster and more accurate than re-deriving the same
// characters from a rendered bitmap). Only when that layer is effectively
// empty (a scanned/photographed document with no text layer at all) does
// this fall back to rendering pages to images and handing them to
// `OCRService` — same OS-version-gated OCR tiers that path already uses.
enum PDFTextExtractor {
    enum PDFError: LocalizedError {
        case tooLarge
        case unreadable

        var errorDescription: String? {
            switch self {
            case .tooLarge: return "That PDF is too large to import (10 MB max)."
            case .unreadable: return "Couldn\u{2019}t read that PDF."
            }
        }
    }

    /// Matches the attachments vertical's own per-file cap (PLAN.md C1:
    /// `byte_size between 1 and 10485760`) — one ceiling for "too big" across
    /// the app, not a separately-invented number for the import path.
    static let maxBytes = 10 * 1024 * 1024

    /// A scanned multi-page PDF (e.g. a whole trip folder someone exported)
    /// could run to dozens of pages — OCR-ing every one serially would make
    /// a single file import take minutes. Ten pages comfortably covers a
    /// single booking confirmation/itinerary document; the rest is dropped
    /// rather than making the user wait indefinitely on a very large file.
    static let maxScannedPages = 10

    /// ponytail: a fixed, unmeasured character-count floor — a text-layer
    /// PDF with real content typically runs to hundreds of characters even
    /// on a short confirmation; a scanned PDF's "text layer" (if PDFKit
    /// finds one at all, e.g. stray embedded metadata) is usually empty or a
    /// handful of stray glyphs. Revisit with real corpus samples if this
    /// starts misclassifying either direction.
    private static let minTextLayerLength = 20

    static func extractText(from data: Data) async throws -> String {
        guard data.count <= maxBytes else { throw PDFError.tooLarge }
        guard let document = PDFDocument(data: data) else { throw PDFError.unreadable }

        let layerText = Self.textLayer(of: document)
        if layerText.count >= minTextLayerLength {
            return layerText
        }
        return try await Self.ocrScannedPages(of: document)
    }

    private static func textLayer(of document: PDFDocument) -> String {
        (0..<document.pageCount)
            .compactMap { document.page(at: $0)?.string }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Serial by construction (`for` + `await`, not a `TaskGroup`) — mirrors
    /// `PasteImportSheet`'s own one-at-a-time batch policy (PLAN.md: on-device
    /// OCR/FoundationModels work competes for the same thermal/rate budget,
    /// so pages within one PDF shouldn't run concurrently either).
    private static func ocrScannedPages(of document: PDFDocument) async throws -> String {
        let pageCount = min(document.pageCount, maxScannedPages)
        var pageTexts: [String] = []
        for index in 0..<pageCount {
            guard let page = document.page(at: index), let cgImage = Self.render(page) else { continue }
            let text = try await OCRService.extractText(from: cgImage)
            if !text.isEmpty { pageTexts.append(text) }
        }
        return pageTexts.joined(separator: "\n\n")
    }

    /// Renders a PDF page to a bitmap at 2x its own point size (PDFKit page
    /// bounds are in points, 72/inch) — a ~144dpi equivalent, generous enough
    /// for OCR without the memory cost of going higher. The renderer's format
    /// scale is pinned to 1 so the output size is exactly `bounds * 2`
    /// regardless of the running device's screen scale — deterministic, and
    /// avoids an unnecessary further 2x/3x multiplication on a Retina device.
    private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let size = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        guard size.width > 0, size.height > 0 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            // PDF page space has its origin bottom-left with Y increasing
            // upward; the renderer's context is top-left/Y-down (UIKit
            // convention) — flip before handing off to `PDFPage.draw`, the
            // standard idiom for rendering a `PDFPage` into a UIKit context.
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: scale, y: -scale)
            page.draw(with: .mediaBox, to: context.cgContext)
        }
        return image.cgImage
    }
}
