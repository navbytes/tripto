import ImageIO
import UniformTypeIdentifiers

/// P8a (avatar photos, `.claude/company/ux-redesign/handoffs/
/// P8-images-plan.md` D2): "pick -> `ImageIO` downsample off-main ->
/// JPEG -> `storage.upload`." This file is the pure first half — plain
/// `Data` in, `Data` out (or throws), no Supabase/SwiftUI/PhotosUI
/// dependency, so it's directly unit-testable with synthetic image bytes.
/// `AvatarStorage.swift` is the second half (the network upload).
enum ImageProcessingError: Error, Equatable {
    /// `CGImageSourceCreateWithData` couldn't even recognize the bytes as
    /// an image — a corrupt file or something that isn't image data at all.
    case invalidImageData
    /// The source decoded, but `CGImageSourceCreateThumbnailAtIndex`
    /// returned `nil` anyway (seen in practice for a handful of exotic/
    /// malformed encodings ImageIO can open but not thumbnail).
    case downsampleFailed
    /// The thumbnail decoded, but re-encoding it as JPEG failed.
    case encodingFailed
}

enum ImageProcessing {
    /// P8a brief's avatar bound. A parameter everywhere below rather than a
    /// hardcoded constant so P8b (photo trip covers, ~1600px per the plan)
    /// can reuse this exact pipeline with its own bound instead of forking it.
    static let avatarMaxPixelSize: CGFloat = 512

    /// Decode -> downsample -> re-encode as JPEG, via
    /// `CGImageSourceCreateThumbnailAtIndex` (P8a brief's exact option set):
    /// `kCGImageSourceThumbnailMaxPixelSize` bounds the longest side;
    /// `kCGImageSourceCreateThumbnailWithTransform` bakes in the EXIF
    /// orientation (a photo straight off `PhotosPicker` is often rotated
    /// purely via metadata — skipping this would upload a sideways avatar);
    /// `kCGImageSourceCreateThumbnailFromImageAlways` forces a fresh
    /// thumbnail generated AT this bound, rather than whatever tiny/
    /// arbitrarily-sized thumbnail a source image happens to already carry
    /// embedded (`kCGImageSourceCreateThumbnailFromImageIfAbsent`'s
    /// behavior) — the brief's "deterministic output size bounds" would
    /// otherwise not hold; `kCGImageSourceShouldCacheImmediately` decodes
    /// the thumbnail eagerly so the returned `CGImage` doesn't lazily
    /// re-touch the source data later on some other thread.
    ///
    /// Per Apple's documented contract for `kCGImageSourceThumbnailMaxPixelSize`,
    /// a source already smaller than `maxPixelSize` is never scaled *up* —
    /// only ever bounded, never padded.
    ///
    /// `async` with no actor isolation of its own (mirrors
    /// `TripArchiveImporter.importArchive`'s doc comment) — the decode/
    /// resize/re-encode is real CPU work, and calling this via `await` from
    /// a `@MainActor` view runs its body off that actor without needing an
    /// explicit `Task.detached`.
    static func downsampledJPEG(
        _ data: Data, maxPixelSize: CGFloat = avatarMaxPixelSize, compressionQuality: CGFloat = 0.8
    ) async throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw ImageProcessingError.invalidImageData
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ImageProcessingError.downsampleFailed
        }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageProcessingError.encodingFailed
        }
        let encodeOptions: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: compressionQuality]
        CGImageDestinationAddImage(destination, thumbnail, encodeOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw ImageProcessingError.encodingFailed
        }
        return encoded as Data
    }
}
