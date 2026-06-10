import AppKit

/// Keeps a resize overlay parented to the window's current frame view and above
/// everything else in it. Zoom, fullscreen round-trips, and AppKit's own glass /
/// titlebar machinery can reparent or reorder frame-view subviews, which silently
/// buries the overlays and "resize stops working".
@MainActor
enum OverlayKeeper {
    /// Set true while an edge/divider drag is live so the keeper doesn't reparent
    /// overlays mid-resize (which thrashes layout and makes the window tremble).
    static var suppressDuringDrag = false

    static func keepOnTop(_ overlay: NSView, in window: NSWindow) {
        // Escape hatch for A/B-testing the keeper itself in self-tests.
        guard ProcessInfo.processInfo.environment["ANF_NO_KEEPER"] != "1" else { return }
        let names: [Notification.Name] = [
            NSWindow.didResizeNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didEnterFullScreenNotification,
            NSWindow.didExitFullScreenNotification,
            NSWindow.didDeminiaturizeNotification,
        ]
        for name in names {
            NotificationCenter.default.addObserver(
                forName: name, object: window, queue: .main
            ) { [weak overlay, weak window] _ in
                MainActor.assumeIsolated { reassert(overlay, window) }
            }
        }
    }

    private static func reassert(_ overlay: NSView?, _ window: NSWindow?) {
        guard !suppressDuringDrag,
              let overlay, let window,
              let frameView = window.contentView?.superview else { return }
        let needsMove = overlay.superview !== frameView
        let buried = frameView.subviews.lastIndex(where: { !($0 is WindowEdgeResizer)
            && !($0 is SidebarDividerResizer) })
            .map { lastContent in
                frameView.subviews.firstIndex(of: overlay).map { $0 < lastContent } ?? true
            } ?? false
        guard needsMove || buried else { return }
        overlay.removeFromSuperview()
        overlay.frame = frameView.bounds
        frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
    }
}
