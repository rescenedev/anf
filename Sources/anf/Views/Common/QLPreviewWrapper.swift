import AppKit
import Quartz

/// Wraps `QLPreviewView` so SwiftUI can drive it. Keeping a single instance and
/// swapping the item avoids the cost of tearing down a preview on every selection.
final class QLPreviewWrapper: NSView {
    private let preview = QLPreviewView(frame: .zero, style: .normal)!
    private var currentURL: URL?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        preview.autoresizingMask = [.width, .height]
        preview.shouldCloseWithWindow = false
        addSubview(preview)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setURL(_ url: URL?) {
        guard url != currentURL else { return }
        currentURL = url
        if let url {
            preview.previewItem = url as NSURL
        } else {
            preview.previewItem = nil
        }
    }

    deinit { preview.close() }
}
