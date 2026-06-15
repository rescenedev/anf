import SwiftUI
import AppKit

/// A draggable split divider used everywhere a SwiftUI region can be resized:
/// the inspector, the terminal drawer, and the pane grid. Draws a hairline with
/// a 9pt grab strip and shows the proper resize cursor.
///
/// Dragging is NOT done with a SwiftUI `DragGesture`: synthetic and real mouse
/// streams both proved unreliable against SwiftUI's gesture arbitration. Each
/// handle embeds an invisible `HandleAnchor` NSView and registers itself with
/// `DividerDragRouter`, a single local event monitor that intercepts mouse
/// events before window dispatch — the same mechanism that made the sidebar
/// divider dependable.
struct DragDividerHandle: View {
    enum Orientation {
        /// Divides left|right content; the user drags horizontally.
        case vertical
        /// Divides top/bottom content; the user drags vertically.
        case horizontal
    }

    let orientation: Orientation
    /// +1 when dragging right/down grows the controlled dimension, -1 otherwise.
    var sign: CGFloat = 1
    let read: () -> CGFloat
    let write: (CGFloat) -> Void
    var onBegan: () -> Void = {}
    var onEnded: () -> Void = {}

    private let gripThickness: CGFloat = 9

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: orientation == .vertical ? 1 : nil,
                       height: orientation == .horizontal ? 1 : nil)
        }
        .frame(width: orientation == .vertical ? gripThickness : nil,
               height: orientation == .horizontal ? gripThickness : nil)
        .frame(maxWidth: orientation == .horizontal ? .infinity : nil,
               maxHeight: orientation == .vertical ? .infinity : nil)
        .background(
            HandleAnchor(orientation: orientation, sign: sign,
                         read: read, write: write, onBegan: onBegan, onEnded: onEnded)
        )
        .onHover { inside in
            if inside {
                (orientation == .vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

/// Invisible NSView that marks a handle's live window-space rect and carries its
/// resize closures into the shared drag router.
private struct HandleAnchor: NSViewRepresentable {
    let orientation: DragDividerHandle.Orientation
    let sign: CGFloat
    let read: () -> CGFloat
    let write: (CGFloat) -> Void
    let onBegan: () -> Void
    let onEnded: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        register(view)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        register(nsView)   // refresh closures if the owning view re-renders
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        MainActor.assumeIsolated { DividerDragRouter.shared.unregister(anchor: nsView) }
    }

    private func register(_ view: NSView) {
        DividerDragRouter.shared.register(.init(
            anchor: view, orientation: orientation, sign: sign,
            read: read, write: write, onBegan: onBegan, onEnded: onEnded))
    }
}

/// One app-wide local event monitor that owns every divider drag. Hit zones are
/// computed live from each handle's anchor NSView, so layout changes, animation
/// and re-renders never desynchronize the drag path.
@MainActor
final class DividerDragRouter {
    static let shared = DividerDragRouter()

    struct Entry {
        weak var anchor: NSView?
        let orientation: DragDividerHandle.Orientation
        let sign: CGFloat
        let read: () -> CGFloat
        let write: (CGFloat) -> Void
        let onBegan: () -> Void
        let onEnded: () -> Void
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var monitor: Any?
    private var active: (entry: Entry, base: CGFloat, start: NSPoint)?

    func register(_ entry: Entry) {
        guard let anchor = entry.anchor else { return }
        entries[ObjectIdentifier(anchor)] = entry
        installIfNeeded()
    }

    func unregister(anchor: NSView) {
        entries.removeValue(forKey: ObjectIdentifier(anchor))
    }

    private func installIfNeeded() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            return MainActor.assumeIsolated { self.route(event) }
        }
    }

    private func route(_ event: NSEvent) -> NSEvent? {
        switch event.type {
        case .leftMouseDown:
            guard let window = event.window else { return event }
            let p = event.locationInWindow
            for (key, entry) in entries {
                guard let anchor = entry.anchor, anchor.window === window else {
                    if entry.anchor == nil { entries.removeValue(forKey: key) }
                    continue
                }
                // Generous grab zone: extend the anchor's thin frame well past its
                // bounds so the divider is easy to catch even though the visible
                // hairline is 1pt.
                let rect = anchor.convert(anchor.bounds, to: nil)
                guard rect.insetBy(dx: -12, dy: -12).contains(p) else { continue }
                Trace.log("router: down consumed at \(p) rect=\(rect)")
                active = (entry, entry.read(), p)
                entry.onBegan()
                return nil
            }
            return event
        case .leftMouseDragged:
            guard let drag = active else { return event }
            let p = event.locationInWindow
            // Horizontal handles use downward-positive deltas (AppKit y is up).
            let delta = drag.entry.orientation == .vertical
                ? p.x - drag.start.x
                : drag.start.y - p.y
            drag.entry.write(drag.base + drag.entry.sign * delta)
            return nil
        case .leftMouseUp:
            guard let drag = active else { return event }
            active = nil
            drag.entry.onEnded()
            return nil
        default:
            return event
        }
    }
}
