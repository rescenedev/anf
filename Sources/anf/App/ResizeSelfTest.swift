import AppKit

/// Headless verification for `WindowEdgeResizer` (synthetic CGEvents don't reach
/// the app without Accessibility). Run with `ANF_RESIZE_SELFTEST=1 anf`: probes
/// hit-testing along the edges and feeds synthetic `NSEvent`s through the drag
/// handlers, printing PASS/FAIL lines, then terminates the app.
@MainActor
enum ResizeSelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["ANF_RESIZE_SELFTEST"] == "1"
    }

    static func run(window: NSWindow, overlay: WindowEdgeResizer) {
        var failures = 0
        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL") \(name)")
            if !ok { failures += 1 }
        }

        guard let frameView = window.contentView?.superview else {
            print("FAIL no frame view"); NSApp.terminate(nil); return
        }
        let b = frameView.bounds

        // 1. Hit-test band: edges resolve to the overlay, the interior does not.
        let probes: [(String, NSPoint, Bool)] = [
            ("left edge", NSPoint(x: b.minX + 4, y: b.midY), true),
            ("right edge", NSPoint(x: b.maxX - 4, y: b.midY), true),
            ("bottom edge", NSPoint(x: b.midX, y: b.minY + 4), true),
            ("top edge", NSPoint(x: b.midX, y: b.maxY - 4), true),
            ("bottom-right corner", NSPoint(x: b.maxX - 12, y: b.minY + 12), true),
            ("interior", NSPoint(x: b.midX, y: b.midY), false),
            // Just inside the 16pt left grab band — still resizes.
            ("inside band edge", NSPoint(x: b.minX + 12, y: b.midY), true),
            // Clearly interior, well past the band.
            ("inside band boundary", NSPoint(x: b.minX + 40, y: b.midY), false),
        ]
        for (name, p, expectOverlay) in probes {
            let hit = frameView.hitTest(p)
            check("hitTest \(name)", (hit === overlay) == expectOverlay)
        }

        // Traffic lights win over the fat top-left corner zone.
        if let close = window.standardWindowButton(.closeButton), let sup = close.superview {
            let center = sup.convert(NSPoint(x: close.frame.midX, y: close.frame.midY), to: nil)
            check("hitTest close button not stolen", frameView.hitTest(center) !== overlay)
        }

        // 2. Drag the right edge +120pt: width grows, left edge stays put.
        let before = window.frame
        let downAt = NSPoint(x: b.maxX - 4, y: b.midY)
        send(.leftMouseDown, at: downAt, to: overlay, window: window)
        send(.leftMouseDragged, at: NSPoint(x: downAt.x + 120, y: downAt.y), to: overlay, window: window)
        send(.leftMouseUp, at: NSPoint(x: downAt.x + 120, y: downAt.y), to: overlay, window: window)
        var f = window.frame
        check("right-edge drag grows width by 120",
              abs(f.width - (before.width + 120)) < 1 && abs(f.minX - before.minX) < 1
              && abs(f.height - before.height) < 1)

        // 3. Drag the left edge -80pt (leftwards): width grows, right edge fixed.
        let beforeL = window.frame
        let downL = NSPoint(x: 4, y: beforeL.height / 2)
        send(.leftMouseDown, at: downL, to: overlay, window: window)
        send(.leftMouseDragged, at: NSPoint(x: downL.x - 80, y: downL.y), to: overlay, window: window)
        send(.leftMouseUp, at: NSPoint(x: downL.x - 80, y: downL.y), to: overlay, window: window)
        f = window.frame
        check("left-edge drag grows width by 80, right edge fixed",
              abs(f.width - (beforeL.width + 80)) < 1 && abs(f.maxX - beforeL.maxX) < 1)

        // 4. min-size clamp: dragging the right edge far left stops at minSize.
        let beforeMin = window.frame
        let downR = NSPoint(x: beforeMin.width - 4, y: beforeMin.height / 2)
        send(.leftMouseDown, at: downR, to: overlay, window: window)
        send(.leftMouseDragged, at: NSPoint(x: downR.x - 5000, y: downR.y), to: overlay, window: window)
        send(.leftMouseUp, at: NSPoint(x: downR.x - 5000, y: downR.y), to: overlay, window: window)
        f = window.frame
        check("right-edge drag clamps at minSize width", abs(f.width - window.minSize.width) < 1)

        print(failures == 0 ? "SELFTEST OK" : "SELFTEST FAILED (\(failures))")
        NSApp.terminate(nil)
    }

    private static func send(_ type: NSEvent.EventType, at locationInWindow: NSPoint,
                             to overlay: WindowEdgeResizer, window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: locationInWindow, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ) else { return }
        switch type {
        case .leftMouseDown: overlay.mouseDown(with: event)
        case .leftMouseDragged: overlay.mouseDragged(with: event)
        case .leftMouseUp: overlay.mouseUp(with: event)
        default: break
        }
    }
}
