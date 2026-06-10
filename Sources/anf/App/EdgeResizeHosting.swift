import AppKit
import SwiftUI

/// Wraps a SwiftUI view in a view controller backed by a plain `NSHostingView`,
/// for use as `NSSplitViewItem` content. Edge-resize hits are handled by
/// `WindowEdgeResizer`, which sits above all content in the window frame view,
/// so the hosting view needs no hit-test tricks.
final class HostingViewController<Content: View>: NSViewController {
    private let rootView: Content

    init(rootView: Content) {
        self.rootView = rootView
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not implemented") }

    override func loadView() {
        let host = NSHostingView(rootView: rootView)
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        view = host
    }
}
