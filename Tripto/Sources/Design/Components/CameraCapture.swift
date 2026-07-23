import SwiftUI
import UIKit

/// G1: wraps `UIImagePickerController(sourceType: .camera)` — SwiftUI has no
/// native camera-capture control (`PhotosUI.PhotosPicker`, the pre-existing
/// `AttachmentStrip` source, only ever reaches the library/Files, never live
/// capture). Presented full-screen (`AttachmentStrip`'s `.fullScreenCover`),
/// same as every other app that hosts the system camera UI — the picker owns
/// its own Cancel/Retake/Use Photo chrome, so this wrapper is pure plumbing:
/// hand the captured image out, or signal cancellation, and let the host
/// dismiss either way.
struct CameraCapture: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    /// `UIImagePickerController.isSourceTypeAvailable(.camera)` is
    /// documented `false` on Simulator (no camera hardware) and on any
    /// camera-less device — callers hide/disable the Camera affordance
    /// entirely when this is `false` so it never dead-ends into a picker
    /// that can't actually capture anything.
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let onCapture: (UIImage) -> Void
        let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            guard let image = info[.originalImage] as? UIImage else {
                onCancel()
                return
            }
            onCapture(image)
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}

extension UIImage {
    /// `UIImagePickerController`'s captured photo commonly comes back with
    /// its pixel buffer still in sensor orientation and only the
    /// `imageOrientation` *flag* set for correct on-screen display — plain
    /// `jpegData(compressionQuality:)` isn't guaranteed to bake that flag
    /// into the JPEG's own EXIF tag, and `ImageProcessing.downsampledJPEG`'s
    /// `kCGImageSourceCreateThumbnailWithTransform` step only corrects
    /// orientation it can actually read from the bytes. Redrawing through
    /// `UIGraphicsImageRenderer` bakes the correct orientation into the
    /// pixels themselves before those bytes are ever produced, so the
    /// uploaded photo can't come out sideways regardless of what (if
    /// anything) the EXIF tag says downstream.
    func normalizedForUpload() -> UIImage {
        guard imageOrientation != .up else { return self }
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in draw(in: CGRect(origin: .zero, size: size)) }
    }
}
