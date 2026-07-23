import CoreGraphics
import UIKit
import XCTest
@testable import Tripto

/// G1 (Camera capture in the attachment flow): the real capture UI
/// (`UIImagePickerController(sourceType: .camera)`) can't run headless on
/// Simulator/CI — these cover exactly the plumbing that CAN run hermetically:
/// the availability guard `AttachmentStrip` keys its "hide the Camera option"
/// decision off, the `Coordinator` hop from the picker delegate callback to
/// `onCapture`/`onCancel`, and the upright-orientation fix-up
/// `attachCameraImage` applies before handing bytes into the same
/// `AttachmentService.attach` pipeline `AttachmentServiceTests` already
/// covers. On-device verification still owns: an actual camera capture
/// round-trip (real `UIImagePickerController` presentation, real sensor
/// orientation).
final class CameraCaptureTests: XCTestCase {
    // MARK: - isAvailable

    /// Deliberately NOT pinned to `false` here — confirmed empirically (not
    /// assumed) that recent Xcode/iOS Simulator versions CAN report `true`
    /// when the host Mac has its own camera (a documented Xcode 15+ feature:
    /// the simulator can pass through the host's webcam), so this suite's
    /// run environment isn't a reliable "always unavailable" fixture. What's
    /// actually under test is narrower: `CameraCapture` forwards the
    /// platform's real answer verbatim rather than second-guessing/
    /// inverting it — exactly the fact `AttachmentStrip`'s "hide Camera when
    /// unavailable" guard depends on, regardless of which way it comes out
    /// on any given machine.
    func testIsAvailableMatchesTheUnderlyingPickerAvailability() {
        XCTAssertEqual(CameraCapture.isAvailable, UIImagePickerController.isSourceTypeAvailable(.camera))
    }

    // MARK: - Coordinator (the capture -> host hop, without a real picker)

    func testCoordinatorForwardsTheOriginalImageToOnCapture() {
        var capturedImage: UIImage?
        var cancelled = false
        let coordinator = CameraCapture.Coordinator(
            onCapture: { capturedImage = $0 }, onCancel: { cancelled = true }
        )
        let image = makeTestImage(width: 10, height: 10)
        coordinator.imagePickerController(
            UIImagePickerController(), didFinishPickingMediaWithInfo: [.originalImage: image]
        )
        XCTAssertTrue(capturedImage === image)
        XCTAssertFalse(cancelled)
    }

    /// Never seen in practice from a real capture, but the info dictionary
    /// is a bag of `Any` the compiler can't guarantee — falls back to
    /// `onCancel` rather than force-unwrapping/crashing.
    func testCoordinatorCancelsWhenInfoHasNoOriginalImage() {
        var captured = false
        var cancelled = false
        let coordinator = CameraCapture.Coordinator(onCapture: { _ in captured = true }, onCancel: { cancelled = true })
        coordinator.imagePickerController(UIImagePickerController(), didFinishPickingMediaWithInfo: [:])
        XCTAssertFalse(captured)
        XCTAssertTrue(cancelled)
    }

    func testCoordinatorDidCancelCallsOnCancel() {
        var cancelled = false
        let coordinator = CameraCapture.Coordinator(onCapture: { _ in }, onCancel: { cancelled = true })
        coordinator.imagePickerControllerDidCancel(UIImagePickerController())
        XCTAssertTrue(cancelled)
    }

    // MARK: - UIImage.normalizedForUpload

    func testNormalizedForUploadReturnsSelfWhenAlreadyUpright() {
        let image = makeTestImage(width: 40, height: 20)
        XCTAssertTrue(image.normalizedForUpload() === image, "an already-upright image needs no redraw at all")
    }

    /// The fix-up this pins: a rotated capture must come out `.up` with the
    /// SAME displayed size it reported going in (`UIGraphicsImageRenderer
    /// (size: size)` in `normalizedForUpload`) — never silently swapped
    /// width/height, never left rotated. Also pins the review fix: `scale`
    /// must stay the SOURCE image's own scale (a camera capture's real 1.0),
    /// never silently inflated to the main screen's scale (3.0 on a Pro) —
    /// that inflation is exactly what turned a ~12MP capture into a
    /// ~110MP/~440MB intermediate bitmap before this bug was fixed.
    func testNormalizedForUploadBakesInARotatedOrientationToUpAndPreservesReportedSize() {
        let image = makeTestImage(width: 40, height: 20, orientation: .right)
        let originalSize = image.size

        let normalized = image.normalizedForUpload()
        XCTAssertEqual(normalized.imageOrientation, .up)
        XCTAssertEqual(normalized.size, originalSize)
        XCTAssertEqual(normalized.scale, image.scale)
    }

    private func makeTestImage(width: Int, height: Int, orientation: UIImage.Orientation = .up) -> UIImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }
}
