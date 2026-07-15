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
}
