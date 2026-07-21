import QuickLook
import SwiftUI
import UIKit

/// A `QLPreviewItem` whose title is the attachment's own `fileName`, not the
/// on-disk cache filename (`AttachmentStore` names cached files
/// `<attachmentId>.<jpg|pdf>`) that would otherwise become QuickLook's
/// nav-bar title. `url` must already be a LOCAL file (cache-through
/// downloaded via `AttachmentService.localFileURL`) — this wrapper never
/// touches the network itself.
final class AttachmentPreviewItem: NSObject, QLPreviewItem, Identifiable {
    let id: UUID
    let previewItemURL: URL?
    let previewItemTitle: String?

    init(id: UUID, url: URL, title: String) {
        self.id = id
        self.previewItemURL = url
        self.previewItemTitle = title
    }
}

/// `UIViewControllerRepresentable` wrap around `QLPreviewController`
/// (BUILD_PLAN.md §6.4 component list: "QuickLook full-screen viewer") —
/// presented via `.sheet(item:)` at the call site (`AttachmentStrip`), one
/// item at a time. SwiftUI's own `.quickLookPreview` modifier titles the nav
/// bar from the URL's last path component, which for a cached attachment is
/// a bare uuid, not the item's real file name — this dedicated wrap is what
/// lets `AttachmentPreviewItem.previewItemTitle` override that instead.
struct QuickLookPreview: UIViewControllerRepresentable {
    let item: AttachmentPreviewItem

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QLPreviewController, context: Context) {
        context.coordinator.item = item
        uiViewController.reloadData()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(item: item)
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var item: AttachmentPreviewItem
        init(item: AttachmentPreviewItem) { self.item = item }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            item
        }
    }
}
