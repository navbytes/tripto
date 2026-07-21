import QuickLook
import SwiftUI
import XCTest

@testable import Tripto

/// Pins the QuickLook wrapper's shape: the preview controller MUST be the
/// root of a UINavigationController, or QuickLook never installs its Done
/// button inside a SwiftUI sheet and a zoomed photo becomes an inescapable
/// screen (owner-reported on device, 2026-07-21). If someone "simplifies"
/// the wrap back to a bare QLPreviewController, this fails.
@MainActor
final class QuickLookPreviewTests: XCTestCase {
    func testPreviewControllerIsWrappedInNavigationController() {
        let item = AttachmentPreviewItem(
            id: UUID(),
            url: URL(fileURLWithPath: "/tmp/fixture.jpg"),
            title: "boarding-pass.jpg"
        )
        let coordinator = QuickLookPreview.Coordinator(item: item)

        let nav = QuickLookPreview.wrappedController(dataSource: coordinator)

        let root = nav.viewControllers.first
        XCTAssertTrue(
            root is QLPreviewController,
            "QuickLookPreview must wrap QLPreviewController in a UINavigationController (Done-button chrome)"
        )
        XCTAssertNotNil((root as? QLPreviewController)?.dataSource, "data source must be wired")
    }
}
