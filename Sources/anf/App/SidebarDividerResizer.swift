import AppKit

/// Makes the sidebar split divider actually draggable. The SwiftUI hosting views
/// on both sides swallow clicks near the hairline divider, so the native
/// NSSplitView drag zone is effectively unreachable. This overlay (a sibling
/// above the content in the window frame view) claims hits within `grabZone` of
/// the divider and drives `setPosition(_:ofDividerAt:)` itself.
final class SidebarDividerResizer: NSView {
    private weak var splitView: NSSplitView?
    var grabZone: CGFloat = 10

    private var monitorDragging = false
    private var eventMonitor: Any?

    @discardableResult
    static func install(in window: NSWindow, splitView: NSSplitView) -> SidebarDividerResizer? {
        guard let frameView = window.contentView?.superview else { return nil }
        let overlay = SidebarDividerResizer(frame: frameView.bounds)
        overlay.splitView = splitView
        overlay.autoresizingMask = [.width, .height]
        frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
        OverlayKeeper.keepOnTop(overlay, in: window)
        overlay.installEventMonitor(window: window)
        NotificationCenter.default.addObserver(
            forName: NSSplitView.didResizeSubviewsNotification, object: splitView,
            queue: .main) { [weak overlay] _ in
            MainActor.assumeIsolated { overlay?.refreshCursorRects() }
        }
        return overlay
    }

    /// Real mouse events are intercepted *before* window dispatch, so divider
    /// drags work no matter what AppKit stacks above the overlay (glass panes,
    /// titlebar machinery, hit-test quirks). The overlay's own mouse handlers
    /// stay as the path for synthetic `sendEvent` traffic and the cursor rect.
    private func installEventMonitor(window: NSWindow) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            return MainActor.assumeIsolated {
                if InputGate.modalActive { return event }
                switch event.type {
                case .leftMouseDown:
                    guard let dividerX = self.dividerXInWindow,
                          abs(event.locationInWindow.x - dividerX) <= self.grabZone
                    else { return event }
                    Trace.log("sidebar: down consumed at \(event.locationInWindow)")
                    self.monitorDragging = true
                    return nil
                case .leftMouseDragged:
                    guard self.monitorDragging else { return event }
                    self.mouseDragged(with: event)
                    return nil
                case .leftMouseUp:
                    guard self.monitorDragging else { return event }
                    self.monitorDragging = false
                    self.mouseUp(with: event)
                    return nil
                default:
                    return event
                }
            }
        }
    }

    private func refreshCursorRects() {
        window?.invalidateCursorRects(for: self)
    }

    /// The divider's x position in window coordinates, or nil when the sidebar
    /// is collapsed.
    private var dividerXInWindow: CGFloat? {
        guard let sv = splitView, let sidebar = sv.arrangedSubviews.first,
              !sidebar.isHidden, sidebar.frame.width > 1 else { return nil }
        return sv.convert(NSPoint(x: sidebar.frame.maxX, y: 0), to: nil).x
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` arrives in superview (frame view == window) coordinates.
        guard let dividerX = dividerXInWindow else { return nil }
        return abs(point.x - dividerX) <= grabZone ? self : nil
    }

    override func resetCursorRects() {
        guard let dividerX = dividerXInWindow else { return }
        let local = convert(NSPoint(x: dividerX, y: 0), from: nil).x
        addCursorRect(NSRect(x: local - grabZone, y: bounds.minY,
                             width: grabZone * 2, height: bounds.height),
                      cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        // Consume the event: the default responder-chain forwarding would hand it
        // to NSSplitView's own divider tracking, whose modal event loop fights our
        // drag (and deadlocks under synthetic events).
    }

    override func mouseDragged(with event: NSEvent) {
        guard let sv = splitView else { return }
        let x = sv.convert(event.locationInWindow, from: nil).x
        sv.setPosition(x, ofDividerAt: 0)
    }

    override func mouseUp(with event: NSEvent) {
        refreshCursorRects()
    }
}
