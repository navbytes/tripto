import ImageIO
import UIKit
import Vision

// C3 (`.claude/company/release-1.2/PLAN.md`): scan-to-add's OCR tier, shared
// by the sheet's photo picker (`PasteImportSheet`) and `PDFTextExtractor`'s
// scanned-PDF fallback. Two backends behind one signature, `#available`-gated
// (never `canImport` — Vision itself has always been available; only
// `RecognizeDocumentsRequest` needs the iOS 26 floor):
//   - iOS 26+: `RecognizeDocumentsRequest` — Vision's structured document
//     read (WWDC25). `DocumentObservation.document.text.transcript` already
//     returns the full page's plain text in natural reading order
//     (paragraphs/lists interleaved correctly), so no manual line-joining is
//     needed on this tier.
//   - iOS 17–25 (this app's deployment floor is 17.0): the older
//     completion-handler-shaped `VNRecognizeTextRequest` (`.accurate`
//     recognition level, language auto-detect). `VNImageRequestHandler
//     .perform(_:)` is synchronous/blocking (Apple's documented behavior for
//     the image handler), so by the time it returns, `request.results` is
//     already populated — no continuation-wrapping needed. Lines are joined
//     with "\n": each observation already comes back top-to-bottom, the
//     closest this tier gets to "reading order".
//
// Every signature here verified directly against the installed iOS 26.5 SDK
// (Vision.swiftinterface / VNRecognizeTextRequest.h / VNRequestHandler.h) —
// not from memory — since `RecognizeDocumentsRequest` is new enough that
// getting a property name wrong would only surface as a build failure.
//
// Returns "" (not a thrown error) when nothing was recognized — a blank
// photo/PDF page isn't a failure, just nothing to extract. Callers
// (`PasteImportSheet`'s batch loop) turn an empty result into the friendly
// "couldn't read this image" row and continue the batch, exactly as they do
// for a thrown error — this file only attempts the recognition, it doesn't
// own that user-facing decision.
enum OCRService {
    enum OCRError: LocalizedError {
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "That doesn\u{2019}t look like a readable image."
            }
        }
    }

    /// For an already-upright source (e.g. `PDFTextExtractor`'s own page
    /// renders, which draw with no rotation). A photo from the user's
    /// library should go through `extractText(from: UIImage)` below instead
    /// — a bare `CGImage` carries no orientation metadata on its own.
    static func extractText(
        from cgImage: CGImage, orientation: CGImagePropertyOrientation = .up
    ) async throws -> String {
        if #available(iOS 26.0, *) {
            return try await extractWithDocumentRecognition(cgImage, orientation: orientation)
        }
        return try extractWithLegacyTextRecognition(cgImage, orientation: orientation)
    }

    /// `UIImage.cgImage` is a raw, unrotated pixel buffer — `imageOrientation`
    /// (the source photo's own EXIF orientation) is the only place "which way
    /// is up" survives, so it's translated and forwarded to Vision rather
    /// than dropped; an un-rotated sideways/upside-down buffer OCRs as
    /// garbage, or nothing at all.
    static func extractText(from image: UIImage) async throws -> String {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        return try await extractText(from: cgImage, orientation: CGImagePropertyOrientation(image.imageOrientation))
    }

    @available(iOS 26.0, *)
    private static func extractWithDocumentRecognition(
        _ cgImage: CGImage, orientation: CGImagePropertyOrientation
    ) async throws -> String {
        var request = RecognizeDocumentsRequest()
        request.textRecognitionOptions.automaticallyDetectLanguage = true
        let observations = try await request.perform(on: cgImage, orientation: orientation)
        return observations
            .map { $0.document.text.transcript }
            .joined(separator: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func extractWithLegacyTextRecognition(
        _ cgImage: CGImage, orientation: CGImagePropertyOrientation
    ) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension CGImagePropertyOrientation {
    /// Apple ships no built-in bridge between `UIImage.Orientation` and
    /// Vision/ImageIO's `CGImagePropertyOrientation` (checked: absent from
    /// every framework's public Swift interface in the iOS 26.5 SDK) — this
    /// is the same case-by-case mapping Apple's own Vision sample code
    /// writes by hand. Matched by CASE NAME, not raw value: the two enums
    /// share identical case names but differ in underlying raw values/order
    /// (verified against both frameworks' headers).
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
