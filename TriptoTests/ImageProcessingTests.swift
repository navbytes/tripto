import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Tripto

/// `ImageProcessing.downsampledJPEG` (P8a — avatar photos): pure `Data` in,
/// `Data` out, so these run against synthetic images built directly with
/// CoreGraphics/ImageIO — no bundled fixture files, no `PhotosUI`/network.
final class ImageProcessingTests: XCTestCase {
    /// A flat-color square/rectangle at an exact pixel size, PNG-encoded —
    /// deliberately not JPEG here, so the downsample test also proves the
    /// pipeline re-encodes to JPEG regardless of the source format.
    private func makeTestImageData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.5, green: 0.2, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return encoded as Data
    }

    private func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let width = properties[kCGImagePropertyPixelWidth] as? Int,
            let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    private func uti(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    func testDownsamplesALargeImageToTheMaxPixelSizeBound() async throws {
        let input = makeTestImageData(width: 2000, height: 1500)
        let output = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 512)

        let size = try XCTUnwrap(pixelSize(of: output))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 512)
        // Aspect ratio survives the resize (within integer-rounding slack).
        let inputAspect = 2000.0 / 1500.0
        let outputAspect = Double(size.width) / Double(size.height)
        XCTAssertEqual(outputAspect, inputAspect, accuracy: 0.05)
    }

    /// Apple's documented `kCGImageSourceThumbnailMaxPixelSize` contract: a
    /// source already smaller than the bound is never scaled *up* — this is
    /// what makes the bound "deterministic" rather than "always exactly
    /// maxPixelSize regardless of the source."
    func testDoesNotUpscaleASmallerImage() async throws {
        let input = makeTestImageData(width: 100, height: 80)
        let output = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 512)

        let size = try XCTUnwrap(pixelSize(of: output))
        XCTAssertLessThanOrEqual(size.width, 100)
        XCTAssertLessThanOrEqual(size.height, 80)
    }

    func testOutputIsAlwaysJPEGRegardlessOfSourceFormat() async throws {
        let input = makeTestImageData(width: 300, height: 300)
        let output = try await ImageProcessing.downsampledJPEG(input)
        XCTAssertEqual(uti(of: output), UTType.jpeg.identifier)
    }

    /// P8b (photo trip covers, blocked-on P8a per `.claude/company/
    /// ux-redesign/handoffs/P8-images-plan.md`) reuses this same pipeline at
    /// its own ~1600px bound — pins that the bound is a real parameter, not
    /// a hardcoded avatar-only constant.
    func testRespectsACustomMaxPixelSizeForFutureCoverPhotoReuse() async throws {
        let input = makeTestImageData(width: 3000, height: 2000)
        let output = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 1600)

        let size = try XCTUnwrap(pixelSize(of: output))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 1600)
        XCTAssertGreaterThan(max(size.width, size.height), 512)
    }

    /// Confirmed empirically (not assumed — an earlier version of this test
    /// pinned `.invalidImageData` and was wrong): `CGImageSourceCreateWithData`
    /// tolerates *any* `Data` — garbage text, even a completely empty
    /// buffer — as "a source" without validating the format upfront, on
    /// this ImageIO version. Both are only ever caught once
    /// `CGImageSourceCreateThumbnailAtIndex` actually tries to decode a
    /// thumbnail from them (`.downsampleFailed`), never at the
    /// source-creation step. This deliberately doesn't pin *which*
    /// `ImageProcessingError` case fires — an internal ImageIO decode-order
    /// detail this app's contract doesn't promise and that could plausibly
    /// differ across OS versions — only that non-image input throws a typed
    /// error rather than crashing or silently "succeeding" with garbage
    /// JPEG bytes.
    func testThrowsATypedErrorForNonImageInputInsteadOfCrashingOrSucceeding() async throws {
        for garbage in [Data("this is not an image".utf8), Data()] {
            do {
                _ = try await ImageProcessing.downsampledJPEG(garbage)
                XCTFail("expected downsampledJPEG to throw for \(garbage)")
            } catch is ImageProcessingError {
                // Expected.
            }
        }
    }

    // MARK: - P8a hardening: exotic source images (`CGBitmapContext` has no
    // CMYK support, so `makeCMYKJPEGData` builds the `CGImage` directly off
    // a raw 4-component buffer rather than drawing through a context; the
    // rest reuse `makeTestImageData`'s "draw through a context" recipe).

    private func makeCMYKJPEGData(width: Int, height: Int) -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            pixels[i] = 200; pixels[i + 1] = 40; pixels[i + 2] = 10; pixels[i + 3] = 5
        }
        let colorSpace = CGColorSpaceCreateDeviceCMYK()
        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        let cgImage = CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
            space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )!

        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return encoded as Data
    }

    private func makeGrayscaleJPEGData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        )!
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return encoded as Data
    }

    /// `nil` if this ImageIO build has no HEIC encoder — confirmed present
    /// on Apple silicon; the point of the test this backs is exercising the
    /// pipeline's HEIC *decode* path, not asserting every possible build
    /// machine can encode one.
    private func makeHEICData(width: Int, height: Int) -> Data? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.1, green: 0.6, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(encoded, UTType.heic.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return encoded as Data
    }

    /// Two solid-color frames (red, then blue) — a minimal animated GIF, the
    /// shape `PhotosPicker` can hand back for a GIF/Live Photo picked from
    /// the library.
    private func makeAnimatedGIFData(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        func frame(_ color: CGColor) -> CGImage {
            let context = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            context.setFillColor(color)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            return context.makeImage()!
        }
        let red = frame(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        let blue = frame(CGColor(red: 0, green: 0, blue: 1, alpha: 1))

        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.gif.identifier as CFString, 2, nil)!
        CGImageDestinationAddImage(destination, red, nil)
        CGImageDestinationAddImage(destination, blue, nil)
        CGImageDestinationFinalize(destination)
        return encoded as Data
    }

    /// The single average pixel over the whole image — coarse, but enough
    /// to tell "mostly red" from "mostly blue" through a lossy JPEG re-encode.
    private func averageColor(of data: Data) -> (r: UInt8, g: UInt8, b: UInt8)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = CGContext(
            data: &pixel, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return (pixel[0], pixel[1], pixel[2])
    }

    /// A degenerate 1x1 source — the smallest possible image, nowhere near
    /// `maxPixelSize` — the same "never scaled up" contract as
    /// `testDoesNotUpscaleASmallerImage` above, at its most extreme boundary.
    func testDoesNotUpscaleAOnePixelImage() async throws {
        let input = makeTestImageData(width: 1, height: 1)
        let output = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 512)
        let size = try XCTUnwrap(pixelSize(of: output))
        XCTAssertEqual(size.width, 1)
        XCTAssertEqual(size.height, 1)
    }

    /// There's no iterative/quality-reduction loop in `downsampledJPEG` —
    /// one decode, one thumbnail, one JPEG encode — so running an
    /// already-small (already-under-bound) image through it a SECOND time
    /// must land on exactly the same dimensions as the first pass, never
    /// shrink further.
    func testReprocessingAnAlreadyDownsampledSmallImageDoesNotShrinkItFurther() async throws {
        let input = makeTestImageData(width: 100, height: 80)
        let firstPass = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 512)
        let secondPass = try await ImageProcessing.downsampledJPEG(firstPass, maxPixelSize: 512)

        let firstSize = try XCTUnwrap(pixelSize(of: firstPass))
        let secondSize = try XCTUnwrap(pixelSize(of: secondPass))
        XCTAssertEqual(firstSize.width, secondSize.width)
        XCTAssertEqual(firstSize.height, secondSize.height)
    }

    /// A 100:1 panorama — `kCGImageSourceThumbnailMaxPixelSize` bounds the
    /// LONGER side only, so the short side shrinks proportionally rather
    /// than getting cropped/padded to a square, and can legitimately land in
    /// the single digits without becoming invalid (0px, or the thumbnail
    /// call failing outright).
    func testExtremeAspectRatioPanoramaIsBoundedOnTheLongerSideOnly() async throws {
        let input = makeTestImageData(width: 10_000, height: 100)
        let output = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 512)

        let size = try XCTUnwrap(pixelSize(of: output))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 512)
        XCTAssertGreaterThan(size.height, 0, "the short side must stay a valid nonzero pixel count")
        XCTAssertLessThan(size.height, 10, "100 * (512/10_000) should round to single digits, not stay near 100")
    }

    /// Photoshop-style CMYK JPEGs are a real (if uncommon) `PhotosPicker`
    /// input.
    func testDownsamplesACMYKJPEGSourceWithoutCrashingOrThrowing() async throws {
        let input = makeCMYKJPEGData(width: 800, height: 600)
        let output = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 512)

        let size = try XCTUnwrap(pixelSize(of: output))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 512)
        XCTAssertEqual(uti(of: output), UTType.jpeg.identifier)
    }

    func testDownsamplesAGrayscaleJPEGSourceWithoutCrashingOrThrowing() async throws {
        let input = makeGrayscaleJPEGData(width: 900, height: 700)
        let output = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 512)

        let size = try XCTUnwrap(pixelSize(of: output))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 512)
        XCTAssertEqual(uti(of: output), UTType.jpeg.identifier)
    }

    /// The common real-world case this file's other fixtures all sidestep:
    /// `PhotosPicker`'s `loadTransferable(type: Data.self)` on a photo
    /// actually taken on an iPhone hands back HEIC bytes, not JPEG/PNG.
    func testDownsamplesARealHEICSourceNotJustPNGOrJPEGFixtures() async throws {
        guard let input = makeHEICData(width: 1200, height: 900) else {
            throw XCTSkip("this machine's ImageIO can't encode HEIC — nothing to feed the pipeline")
        }
        XCTAssertEqual(uti(of: input), UTType.heic.identifier, "fixture setup sanity check, not the pipeline itself")

        let output = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 512)
        let size = try XCTUnwrap(pixelSize(of: output))
        XCTAssertLessThanOrEqual(max(size.width, size.height), 512)
        XCTAssertEqual(uti(of: output), UTType.jpeg.identifier)
    }

    /// `CGImageSourceCreateThumbnailAtIndex` is always called with index `0`
    /// (`ImageProcessing.downsampledJPEG`'s own doc comment) — for a
    /// multi-frame GIF, that's the first frame, regardless of how many
    /// follow it. Doesn't pin success as the only acceptable outcome (same
    /// reasoning as `testThrowsATypedErrorForNonImageInputInsteadOfCrashingOrSucceeding`
    /// above) — only that an animated source can never crash, and any
    /// failure is a typed error, never silent garbage. Confirmed empirically
    /// on this ImageIO version: it succeeds, using frame 0 (red) — checked
    /// below via the output's average color, never frame 1's blue.
    func testAnimatedGIFEitherProcessesTheFirstFrameOrRejectsButNeverCrashes() async throws {
        let input = makeAnimatedGIFData(width: 80, height: 60)
        do {
            let output = try await ImageProcessing.downsampledJPEG(input, maxPixelSize: 512)
            let size = try XCTUnwrap(pixelSize(of: output))
            XCTAssertLessThanOrEqual(max(size.width, size.height), 512)
            let color = try XCTUnwrap(averageColor(of: output))
            XCTAssertGreaterThan(color.r, color.b, "expected frame 0 (red) to win, never frame 1 (blue)")
        } catch is ImageProcessingError {
            // Also acceptable — a typed rejection, never a crash.
        }
    }

    // MARK: - Security D5: GPS/Exif stripping is a load-bearing side effect
    // of re-encoding through a decoded `CGImage` (`CGImageDestinationAddImage`)
    // rather than copying source properties (`CGImageDestinationAddImageFromSource`
    // / explicit `kCGImageDestinationMetadata`) — this pins it as a real
    // regression test, not just an assumption, so a future refactor toward
    // "preserve more of the original" can't silently reintroduce a location leak.

    private func propertiesOf(_ data: Data) -> [CFString: Any]? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    }

    private func makeJPEGDataWithGPSAndExif(width: Int, height: Int) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.3, green: 0.3, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let gps: [CFString: Any] = [
            kCGImagePropertyGPSLatitude: 37.7749,
            kCGImagePropertyGPSLatitudeRef: "N",
            kCGImagePropertyGPSLongitude: 122.4194,
            kCGImagePropertyGPSLongitudeRef: "W"
        ]
        let exif: [CFString: Any] = [kCGImagePropertyExifDateTimeOriginal: "2026:01:01 12:00:00"]
        let properties: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: gps,
            kCGImagePropertyExifDictionary: exif
        ]

        let encoded = NSMutableData()
        let destination = CGImageDestinationCreateWithData(encoded, UTType.jpeg.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)
        CGImageDestinationFinalize(destination)
        return encoded as Data
    }

    /// Fixture sanity check + the actual regression: a JPEG carrying real
    /// GPS/Exif metadata comes out the other side of `downsampledJPEG` with
    /// no GPS dictionary and none of the original (personally-identifying)
    /// Exif fields. Confirmed empirically (not assumed): the JPEG encoder
    /// itself always writes a minimal, harmless Exif dictionary of its own
    /// (`PixelXDimension`/`PixelYDimension`/`ColorSpace` — the image's own
    /// technical properties, present on every JPEG regardless of input), so
    /// asserting "no Exif dictionary at all" is the wrong, over-strict bar —
    /// the leak this guards against is the *original* `DateTimeOriginal`
    /// (stand-in for any personal/camera field) surviving, not that boilerplate.
    func testDownsampledJPEGStripsGPSAndExifMetadata() async throws {
        let input = makeJPEGDataWithGPSAndExif(width: 400, height: 300)
        let inputProperties = try XCTUnwrap(propertiesOf(input), "fixture setup sanity check, not the pipeline itself")
        XCTAssertNotNil(inputProperties[kCGImagePropertyGPSDictionary], "fixture must actually carry GPS metadata")
        let inputExif = try XCTUnwrap(
            inputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any], "fixture must actually carry Exif metadata"
        )
        XCTAssertNotNil(inputExif[kCGImagePropertyExifDateTimeOriginal], "fixture sanity check")

        let output = try await ImageProcessing.downsampledJPEG(input)
        let outputProperties = try XCTUnwrap(propertiesOf(output))
        XCTAssertNil(outputProperties[kCGImagePropertyGPSDictionary], "GPS metadata must never survive into the uploaded JPEG")
        let outputExif = outputProperties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        XCTAssertNil(
            outputExif?[kCGImagePropertyExifDateTimeOriginal], "the original Exif field must never survive into the uploaded JPEG"
        )
    }
}
