import AppKit

/// Widens the window's edge-resize hit zone. The system resize band on a titled
/// `.fullSizeContentView` window is only a couple of points wide and is swallowed
/// by the SwiftUI/WKWebView content, so grabbing an edge is unreliable. This
/// overlay sits above the content (a sibling inside the window's frame view) and
/// drives the resize itself via `setFrame`.
///
/// Cursor handling does NOT use cursor rects or tracking areas: WKWebView installs
/// its own aggressive tracking areas that constantly reset the cursor to arrow, so
/// any tracking-area approach flickers. Instead the shared event monitor watches
/// `mouseMoved` and, while the pointer is inside a resize zone, sets the resize
/// cursor AND consumes the event so the content views never get a chance to reset
/// it. This is the only approach that reliably wins over WKWebView.
final class WindowEdgeResizer: NSView {
    private struct Edges: OptionSet {
        let rawValue: Int
        static let left = Edges(rawValue: 1 << 0)
        static let right = Edges(rawValue: 1 << 1)
        static let bottom = Edges(rawValue: 1 << 2)
        static let top = Edges(rawValue: 1 << 3)
    }

    // Moderate side/bottom grab bands. The top stays tight so grabbing the
    // titlebar is always a MOVE, never a resize (that fight causes trembling).
    var edgeMargin: CGFloat = 16
    var cornerMargin: CGFloat = 32
    var topEdgeMargin: CGFloat = 6
    var topCornerMargin: CGFloat = 24

    private var dragEdges: Edges = []
    private var startFrame: NSRect = .zero
    private var startMouse: NSPoint = .zero
    private var eventMonitor: Any?
    private var wasInZone = false

    @discardableResult
    static func install(in window: NSWindow) -> WindowEdgeResizer? {
        guard let frameView = window.contentView?.superview else { return nil }
        let overlay = WindowEdgeResizer(frame: frameView.bounds)
        overlay.autoresizingMask = [.width, .height]
        frameView.addSubview(overlay, positioned: .above, relativeTo: nil)
        OverlayKeeper.keepOnTop(overlay, in: window)
        // Required so the local monitor receives mouseMoved for live cursor updates.
        window.acceptsMouseMovedEvents = true
        overlay.installEventMonitor(window: window)
        return overlay
    }

    /// One local monitor intercepts real mouse events before window dispatch:
    /// `mouseMoved` drives the cursor (consumed in-zone so WKWebView can't reset
    /// it), and the button events drive the resize drag.
    private func installEventMonitor(window: NSWindow) {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .mouseMoved, .cursorUpdate]
        ) { [weak self, weak window] event in
            guard let self, let window, event.window === window else { return event }
            return MainActor.assumeIsolated {
                switch event.type {
                case .mouseMoved, .cursorUpdate:
                    return self.handleMouseMoved(event, window: window)
                case .leftMouseDown:
                    guard window.styleMask.contains(.resizable),
                          !window.styleMask.contains(.fullScreen) else {
                        Trace.log("edge: down rejected styleMask=\(window.styleMask.rawValue)")
                        return event
                    }
                    let local = self.convert(event.locationInWindow, from: nil)
                    guard !self.edges(at: local).isEmpty,
                          !self.overlapsWindowControl(local) else { return event }
                    Trace.log("edge: down consumed at \(local)")
                    self.mouseDown(with: event)
                    return nil
                case .leftMouseDragged:
                    guard !self.dragEdges.isEmpty else { return event }
                    self.mouseDragged(with: event)
                    return nil
                case .leftMouseUp:
                    guard !self.dragEdges.isEmpty else { return event }
                    self.mouseUp(with: event)
                    return nil
                default:
                    return event
                }
            }
        }
    }

    /// Returns nil (consume) while in a resize zone so the resize cursor sticks;
    /// otherwise returns the event so content views manage their own cursor.
    private func handleMouseMoved(_ event: NSEvent, window: NSWindow) -> NSEvent? {
        guard window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen) else {
            if wasInZone { NSCursor.arrow.set(); wasInZone = false }
            return event
        }
        let local = convert(event.locationInWindow, from: nil)
        let e = edges(at: local)
        let inZone = !e.isEmpty && !overlapsWindowControl(local)
        if inZone != wasInZone {
            Trace.log("edge: \(event.type == .cursorUpdate ? "cursorUpdate" : "mouseMoved") inZone=\(inZone) at \(local)")
        }
        if inZone {
            cursor(for: e).set()
            wasInZone = true
            return event.type == .cursorUpdate ? nil : event
        } else {
            if wasInZone { NSCursor.arrow.set(); wasInZone = false }
            return event
        }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window, window.styleMask.contains(.resizable),
              !window.styleMask.contains(.fullScreen) else { return nil }
        let local = convert(point, from: superview)
        guard !edges(at: local).isEmpty else { return nil }
        if overlapsWindowControl(local) { return nil }
        return self
    }

    private func overlapsWindowControl(_ p: NSPoint) -> Bool {
        guard let window else { return false }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        for type in buttons {
            guard let button = window.standardWindowButton(type), button.superview != nil
            else { continue }
            let inWindow = button.convert(button.bounds.insetBy(dx: -2, dy: -2), to: nil)
            if convert(inWindow, from: nil).contains(p) { return true }
        }
        return false
    }

    private func edges(at p: NSPoint, slack: CGFloat = 0) -> Edges {
        let b = bounds
        let em = edgeMargin + slack, cm = cornerMargin + slack
        let tem = topEdgeMargin + slack, tcm = topCornerMargin + slack
        guard b.insetBy(dx: -1, dy: -1).contains(p) else { return [] }
        // Bottom corners generous; top corners tight (titlebar move area).
        if p.x <= b.minX + cm && p.y <= b.minY + cm { return [.left, .bottom] }
        if p.x >= b.maxX - cm && p.y <= b.minY + cm { return [.right, .bottom] }
        if p.x <= b.minX + tcm && p.y >= b.maxY - tcm { return [.left, .top] }
        if p.x >= b.maxX - tcm && p.y >= b.maxY - tcm { return [.right, .top] }
        if p.x <= b.minX + em { return .left }
        if p.x >= b.maxX - em { return .right }
        if p.y <= b.minY + em { return .bottom }
        if p.y >= b.maxY - tem { return .top }
        return []
    }

    private func cursor(for e: Edges) -> NSCursor {
        if #available(macOS 15.0, *) {
            if e.contains(.left)  && e.contains(.bottom) { return .frameResize(position: .bottomLeft,  directions: .all) }
            if e.contains(.right) && e.contains(.bottom) { return .frameResize(position: .bottomRight, directions: .all) }
            if e.contains(.left)  && e.contains(.top)    { return .frameResize(position: .topLeft,     directions: .all) }
            if e.contains(.right) && e.contains(.top)    { return .frameResize(position: .topRight,    directions: .all) }
            if e.contains(.left)  { return .frameResize(position: .left,   directions: .all) }
            if e.contains(.right) { return .frameResize(position: .right,  directions: .all) }
            if e.contains(.top)   { return .frameResize(position: .top,    directions: .all) }
            return .frameResize(position: .bottom, directions: .all)
        } else {
            if e.contains(.left) || e.contains(.right) { return .resizeLeftRight }
            return .resizeUpDown
        }
    }

    // MARK: - Drag

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragEdges = edges(at: convert(event.locationInWindow, from: nil))
        guard !dragEdges.isEmpty else { return super.mouseDown(with: event) }
        startFrame = window.frame
        startMouse = window.convertPoint(toScreen: event.locationInWindow)
        OverlayKeeper.suppressDuringDrag = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragEdges.isEmpty, let window else { return }
        let mouse = window.convertPoint(toScreen: event.locationInWindow)
        let dx = mouse.x - startMouse.x
        let dy = mouse.y - startMouse.y
        let minS = window.minSize
        let maxS = window.maxSize
        var f = startFrame

        if dragEdges.contains(.right) {
            f.size.width = (startFrame.width + dx).clamped(minS.width, maxS.width)
        }
        if dragEdges.contains(.left) {
            f.size.width = (startFrame.width - dx).clamped(minS.width, maxS.width)
            f.origin.x = startFrame.maxX - f.width
        }
        if dragEdges.contains(.top) {
            f.size.height = (startFrame.height + dy).clamped(minS.height, maxS.height)
        }
        if dragEdges.contains(.bottom) {
            f.size.height = (startFrame.height - dy).clamped(minS.height, maxS.height)
            f.origin.y = startFrame.maxY - f.height
        }
        window.setFrame(f, display: true)
    }

    override func mouseUp(with event: NSEvent) {
        dragEdges = []
        OverlayKeeper.suppressDuringDrag = false
    }
}

private extension CGFloat {
    func clamped(_ lo: CGFloat, _ hi: CGFloat) -> CGFloat {
        Swift.min(Swift.max(self, lo), hi)
    }
}
