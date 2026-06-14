import AppKit
import SwiftUI

// SwiftUI's `App`/`WindowGroup` scene lifecycle does not launch reliably for an
// SPM executable built with Command Line Tools (no full Xcode): `App.init` runs
// but `applicationDidFinishLaunching` never fires, so no window appears. We drive
// AppKit directly — create the NSWindow and host the SwiftUI tree in an
// NSHostingController.

extension NSWindow {
    /// The main split view controller, whether it's the contentViewController
    /// itself or wrapped in the root blur container.
    var anfSplitViewController: NSSplitViewController? {
        if let split = contentViewController as? NSSplitViewController { return split }
        return contentViewController?.children
            .compactMap { $0 as? NSSplitViewController }.first
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    /// One shared keyboard monitor for the whole app; it acts on whichever
    /// window is key (resolved through WindowRegistry), so N windows don't mean
    /// N monitors fighting over every keystroke.
    private var keyboard: KeyboardController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            keyboard = KeyboardController()

            let controller = AnfWindowController(workspace: WorkspaceModel(), restoreFrame: true)
            let window = controller.window
            let workspace = controller.workspace
            Trace.log("launch: frame=\(window.frame) styleMask=\(window.styleMask.rawValue)")
            _ = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                Trace.log("app: down at \(event.locationInWindow) winFrame=\(event.window?.frame ?? .zero)")
                return event
            }

            NSApp.activate(ignoringOtherApps: true)

            if ResizeSelfTest.isRequested,
               let resizer = WindowEdgeResizer.install(in: window) {
                DispatchQueue.main.async { ResizeSelfTest.run(window: window, overlay: resizer) }
            }
            if UISelfTest.isRequested {
                UISelfTest.run(window: window, workspace: workspace)
            }
            if LayoutBench.isRequested {
                LayoutBench.run(window: window, workspace: workspace)
            }
            if TerminalSmoke.isRequested {
                TerminalSmoke.run(workspace: workspace)
            }
            if let pick = ProcessInfo.processInfo.environment["ANF_SELECT_FIRST"] {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    workspace.inspectorVisible = true
                    let items = workspace.active.items.filter { !$0.isBrowsableContainer }
                    let f = pick == "1"
                        ? items.first
                        : items.first { $0.name.localizedCaseInsensitiveContains(pick) } ?? items.first
                    if let f { workspace.active.selection = [f.id] }
                }
            }
        }
    }

    /// ⌘N — open another independent window with a fresh workspace.
    @MainActor
    static func newWindow() {
        _ = AnfWindowController(workspace: WorkspaceModel(), restoreFrame: false)
        NSApp.activate(ignoringOtherApps: true)
    }

    // Re-open a window when the user clicks the Dock icon with none open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { MainActor.assumeIsolated { AppController.newWindow() } }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { WindowRegistry.saveAll() }
    }
}

/// App entry point. Lives in the `anf` library so the logic is unit-testable;
/// the thin `anfapp` executable target just calls this.
public func anfMain() {
    // Toolbar icons rely on hover tooltips to explain themselves — the system
    // default delay (~1.5s) makes them feel absent, so shorten it app-wide.
    UserDefaults.standard.register(defaults: ["NSInitialToolTipDelay": 500])
    HangWatchdog.startIfRequested()
    _ = VaultWatcher.shared   // resume watching protected folders from last launch
    // Return allocator slack to the OS periodically: after a burst (26k listing,
    // bulk copy) malloc keeps freed pages dirty, which reads as a bloated
    // footprint in Activity Monitor even though the live heap is ~30MB.
    let memoryTrim = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
    memoryTrim.schedule(deadline: .now() + 30, repeating: 30)
    memoryTrim.setEventHandler { malloc_zone_pressure_relief(nil, 0) }
    memoryTrim.activate()
    objc_setAssociatedObject(NSApplication.shared, "anf.memtrim", memoryTrim, .OBJC_ASSOCIATION_RETAIN)
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    MainActor.assumeIsolated {
        MainMenu.install()
        _ = Keymap.shared   // load settings now → migrates any plaintext API key into the Keychain at launch
    }
    // Keep the delegate alive for the app's lifetime.
    objc_setAssociatedObject(app, "anf.controller", controller, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
