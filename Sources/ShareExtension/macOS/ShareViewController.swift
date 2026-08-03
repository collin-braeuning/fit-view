import AppKit
import SwiftUI

/// `NSExtensionPrincipalClass` for the macOS share extension (see
/// `Info.plist` in this directory) — just a thin host for the
/// platform-agnostic `ShareEditView`.
final class ShareViewController: NSViewController {
    override func loadView() {
        let hosting = NSHostingController(rootView: ShareEditView(extensionContext: extensionContext))
        addChild(hosting)
        view = hosting.view
        preferredContentSize = NSSize(width: 420, height: 260)
    }
}
