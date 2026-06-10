import AppKit

/// Drives the in-window resize handles (inspector / pane splits / terminal) with
/// synthetic NSEvents through `window.sendEvent`, which exercises the real SwiftUI
/// gesture path without needing Accessibility. Run with `ANF_UI_SELFTEST=1 anf`.
@MainActor
enum UISelfTest {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["ANF_UI_SELFTEST"] == "1"
    }

    private static let grip: CGFloat = 9

    static func run(window: NSWindow, workspace: WorkspaceModel) {
        Task { @MainActor in
            var failures = 0
            func check(_ name: String, _ ok: Bool) {
                print("\(ok ? "PASS" : "FAIL") \(name)")
                if !ok { failures += 1 }
            }
            func settle() async { try? await Task.sleep(nanoseconds: 400_000_000) }

            // Watchdog: a synthetic mouseDown that strays into an AppKit modal
            // tracking loop hangs the main thread — force-exit so output flushes.
            DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
                print("UISELFTEST TIMEOUT (main thread stuck)")
                exit(2)
            }

            // Cold start: first layout after a fresh build can lag well past one
            // settle interval; wait longer before measuring anything.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            // Reset shared state so repeated runs never start at a clamp limit.
            workspace.inspectorWidth = 300
            workspace.splitRatioH = 0.5
            workspace.splitRatioV = 0.5
            let winSize = window.contentView?.frame.size ?? .zero
            // NB: `window.contentView` is the controller's *container* NSView —
            // the actual NSSplitView lives on the NSSplitViewController.
            let splitView = (window.contentViewController as? NSSplitViewController)?.splitView
            func contentLeftNow() -> CGFloat {
                guard let sidebar = splitView?.arrangedSubviews.first else { return 0 }
                return sidebar.convert(NSPoint(x: sidebar.bounds.maxX, y: 0), to: nil).x + 1
            }

            // -- 0. Sidebar: drag the split divider 60pt right → sidebar grows.
            if let sv = (window.contentViewController as? NSSplitViewController)?.splitView,
               let sidebar = sv.arrangedSubviews.first {
                let s0 = sidebar.frame.width
                let probe = NSPoint(x: s0, y: 300)
                let hit = window.contentView?.superview?.hitTest(probe)
                if hit is SidebarDividerResizer {
                    await drag(window, from: probe, by: NSPoint(x: 60, y: 0))
                    await settle()
                    check("sidebar drag grows width (\(Int(s0)) → \(Int(sidebar.frame.width)))",
                          sidebar.frame.width > s0 + 20)
                } else {
                    // Sending a synthetic mouseDown into NSSplitView's own divider
                    // enters its modal tracking loop and hangs — skip the drag.
                    check("sidebar overlay owns divider hit (got \(hit.map { String(describing: type(of: $0)) } ?? "nil"))",
                          false)
                }
            } else {
                check("sidebar split view reachable", false)
            }

            // SwiftUI gesture recognition can miss the very first synthetic drag
            // on a cold launch — retry a few times; a real breakage fails all.
            func dragUntil(_ name: String, attempts: Int = 3,
                           from: () -> NSPoint, by: NSPoint,
                           passed: () -> Bool) async {
                for _ in 0..<attempts {
                    await drag(window, from: from(), by: by)
                    await settle()
                    if passed() { break }
                }
                check(name, passed())
            }

            // -- 1. Inspector width: drag its handle 60pt left → width grows.
            workspace.inspectorVisible = true
            await settle()
            let w0 = workspace.inspectorWidth
            await dragUntil("inspector drag grows width (\(Int(w0))→)",
                            from: { NSPoint(x: winSize.width - workspace.inspectorWidth - grip / 2, y: 300) },
                            by: NSPoint(x: -60, y: 0),
                            passed: { workspace.inspectorWidth > w0 + 50 })
            workspace.inspectorVisible = false

            // -- 2. Dual columns: drag the column handle right → ratio grows.
            workspace.setLayout(.dual)
            await settle()
            let contentLeft = contentLeftNow()   // sidebar width changed in test 0
            let contentW = winSize.width - contentLeft
            let r0 = workspace.splitRatioH
            await dragUntil("dual column drag grows ratio",
                            from: { NSPoint(x: contentLeft + (contentW - grip) * workspace.splitRatioH + grip / 2, y: 300) },
                            by: NSPoint(x: 80, y: 0),
                            passed: { workspace.splitRatioH > r0 + 0.02 })

            // -- 3. Rows: drag the row handle down → top pane ratio grows.
            workspace.setLayout(.rows)
            await settle()
            let v0 = workspace.splitRatioV
            // Pane area spans from below the titlebar to the window bottom.
            let paneTop = window.contentLayoutRect.height   // in view coords from bottom
            await dragUntil("rows drag grows top ratio",
                            from: {
                                let yFromTop = (paneTop - grip) * workspace.splitRatioV + grip / 2
                                return NSPoint(x: contentLeft + contentW / 2, y: paneTop - yFromTop)
                            },
                            by: NSPoint(x: 0, y: -60),   // window-y down = drag down
                            passed: { workspace.splitRatioV > v0 + 0.02 })

            workspace.setLayout(.single)

            // -- 4. Stress: zoom / sidebar collapse / fullscreen must not bury
            // the overlays (this is exactly how "resize stopped working again"
            // reproduced — frame-view churn reorders subviews).
            func sidebarDragCheck(_ stage: String) async {
                guard let sv = splitView, let sidebar = sv.arrangedSubviews.first else {
                    check("\(stage): split view reachable", false); return
                }
                sv.setPosition(220, ofDividerAt: 0)
                await settle()
                let s0 = sidebar.frame.width
                let dividerX = sidebar.convert(NSPoint(x: sidebar.bounds.maxX, y: 0), to: nil).x
                let probe = NSPoint(x: dividerX, y: 300)
                let hit = window.contentView?.superview?.hitTest(probe)
                guard hit is SidebarDividerResizer else {
                    check("\(stage): overlay owns divider (got \(hit.map { String(describing: type(of: $0)) } ?? "nil"))", false)
                    return
                }
                await drag(window, from: probe, by: NSPoint(x: 40, y: 0))
                await settle()
                check("\(stage): sidebar drag works (\(Int(s0)) → \(Int(sidebar.frame.width)))",
                      sidebar.frame.width > s0 + 15)
            }
            func edgeProbeCheck(_ stage: String) {
                guard let frameView = window.contentView?.superview else {
                    check("\(stage): frame view reachable", false); return
                }
                let b = frameView.bounds
                let hit = frameView.hitTest(NSPoint(x: b.maxX - 4, y: b.midY))
                check("\(stage): window-edge overlay alive", hit is WindowEdgeResizer)
            }

            window.zoom(nil)
            await settle(); await settle()
            edgeProbeCheck("after zoom")
            await sidebarDragCheck("after zoom")
            window.zoom(nil)
            await settle()

            if let split = window.contentViewController as? NSSplitViewController,
               let item = split.splitViewItems.first {
                item.isCollapsed = true
                await settle()
                item.isCollapsed = false
                await settle(); await settle()
                await sidebarDragCheck("after sidebar collapse toggle")
            }

            window.toggleFullScreen(nil)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            await sidebarDragCheck("in fullscreen")
            window.toggleFullScreen(nil)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            edgeProbeCheck("after fullscreen round-trip")
            await sidebarDragCheck("after fullscreen round-trip")

            print(failures == 0 ? "UISELFTEST OK" : "UISELFTEST FAILED (\(failures))")
            NSApp.terminate(nil)
        }
    }

    private static func drag(_ window: NSWindow, from: NSPoint, by delta: NSPoint) async {
        // Yield to the run loop between events — SwiftUI gesture recognition
        // updates asynchronously and drops a burst posted in one synchronous turn.
        post(.leftMouseDown, at: from, in: window)
        try? await Task.sleep(nanoseconds: 20_000_000)
        let steps = 8
        for i in 1...steps {
            let p = NSPoint(x: from.x + delta.x * CGFloat(i) / CGFloat(steps),
                            y: from.y + delta.y * CGFloat(i) / CGFloat(steps))
            post(.leftMouseDragged, at: p, in: window)
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        post(.leftMouseUp, at: NSPoint(x: from.x + delta.x, y: from.y + delta.y), in: window)
        try? await Task.sleep(nanoseconds: 20_000_000)
    }

    private static func post(_ type: NSEvent.EventType, at point: NSPoint, in window: NSWindow) {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            eventNumber: Int.random(in: 1...1_000_000), clickCount: 1, pressure: 1
        ) else { return }
        // Dispatch through NSApp so local event monitors (the real-mouse drag
        // path for the resize overlays) are exercised too, not just hitTest.
        NSApp.sendEvent(event)
    }
}
