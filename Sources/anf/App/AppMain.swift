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
    static let frameKey = "anf.window.frame.v2"

    private var window: NSWindow!
    private var workspace: WorkspaceModel!
    private var keyboard: KeyboardController!
    private var toolbarController: WindowToolbarController!

    @MainActor
    private func saveWindowFrame() {
        guard let window, !ResizeSelfTest.isRequested, !UISelfTest.isRequested else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            let workspace = WorkspaceModel()
            self.workspace = workspace
            self.keyboard = KeyboardController(workspace: workspace)
            ViewMenuController.shared.workspace = workspace

            // Native split: a real sidebar item (full-height floating glass on macOS
            // 26, correct traffic-light inset) + content. This is how Finder is built
            // and it makes window resizing work natively — no SwiftUI hacks.
            // Edge-resize-friendly hosting so the window grabs resize from its edges.
            let sidebarVC = SidebarViewController(workspace: workspace)
            let contentHC = HostingViewController(rootView: ContentRootView(workspace: workspace))

            let split = NSSplitViewController()
            let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
            sidebarItem.minimumThickness = 184
            sidebarItem.maximumThickness = 340
            sidebarItem.canCollapse = true
            sidebarItem.allowsFullHeightLayout = true
            split.addSplitViewItem(sidebarItem)
            let contentItem = NSSplitViewItem(viewController: contentHC)
            contentItem.minimumThickness = 420
            split.addSplitViewItem(contentItem)

            // `.fullSizeContentView` lets the sidebar run the full window height
            // (Finder-style glass under the titlebar). It also swallows the OS's
            // already-thin edge-resize margins — WindowEdgeResizer below restores
            // resize with a much fatter grab zone.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false
            )
            window.title = "anf"
            window.titleVisibility = .hidden
            window.minSize = NSSize(width: 720, height: 460)
            // Non-opaque so the content area's behind-window blur reveals the
            // desktop (true translucency).
            window.isOpaque = false
            window.backgroundColor = .clear
            // Root-level blur UNDER the split view: with a clear window, the
            // sidebar/panels otherwise float over nothing and their square edges
            // meet the window's rounded corners awkwardly (visible at the bottom-
            // left). A full-bleed NSVisualEffectView is clipped to the window
            // shape by the system, so every corner stays Finder-smooth.
            let container = NSViewController()
            let base = NSVisualEffectView()
            base.material = .underWindowBackground
            base.blendingMode = .behindWindow
            base.state = .active
            container.view = base
            container.addChild(split)
            split.view.translatesAutoresizingMaskIntoConstraints = false
            base.addSubview(split.view)
            NSLayoutConstraint.activate([
                split.view.leadingAnchor.constraint(equalTo: base.leadingAnchor),
                split.view.trailingAnchor.constraint(equalTo: base.trailingAnchor),
                split.view.topAnchor.constraint(equalTo: base.topAnchor),
                split.view.bottomAnchor.constraint(equalTo: base.bottomAnchor),
            ])
            window.contentViewController = container
            // Self-test runs resize everything — keep them out of the autosaved
            // window/sidebar geometry so they can't pollute the user's layout.
            let inSelfTest = ResizeSelfTest.isRequested || UISelfTest.isRequested
            if !inSelfTest {
                // Remember the sidebar width across launches.
                split.splitView.autosaveName = "anf.main.split"
            }

            let toolbarController = WindowToolbarController(workspace: workspace)
            self.toolbarController = toolbarController
            window.toolbar = toolbarController.makeToolbar()
            window.toolbarStyle = .unified

            // Window frame is remembered manually. NSWindow's frame autosave
            // mis-anchored multi-display frames on restore (titlebar pushed
            // above the screen top → the window could neither move nor resize);
            // here the saved frame is re-validated against the live screens and
            // constrained so the titlebar always stays reachable.
            func defaultPlacement() {
                window.setContentSize(NSSize(width: 1180, height: 760))
                window.center()
            }
            if inSelfTest {
                defaultPlacement()
            } else if let saved = UserDefaults.standard.string(forKey: Self.frameKey) {
                let f = NSRectFromString(saved)
                let bestScreen = NSScreen.screens.max { a, b in
                    let ia = a.frame.intersection(f), ib = b.frame.intersection(f)
                    return ia.width * ia.height < ib.width * ib.height
                }
                if f.width >= 400, f.height >= 300,
                   let screen = bestScreen, screen.frame.intersects(f) {
                    window.setFrame(window.constrainFrameRect(f, to: screen), display: false)
                } else {
                    defaultPlacement()
                }
            } else {
                defaultPlacement()
            }
            window.makeKeyAndOrderFront(nil)
            // Sidebar grip first, edge resizer last — the window-edge band wins on top.
            let sidebarGrip = SidebarDividerResizer.install(in: window, splitView: split.splitView)
            let resizer = WindowEdgeResizer.install(in: window)
            Trace.log("launch: overlays sidebar=\(sidebarGrip != nil) edge=\(resizer != nil) frame=\(window.frame) styleMask=\(window.styleMask.rawValue)")
            // Field diagnostics: log every unconsumed primary click so a broken
            // resize/move reproduces with evidence in /tmp/anf-trace.log.
            _ = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
                Trace.log("app: down at \(event.locationInWindow) winFrame=\(event.window?.frame ?? .zero)")
                return event
            }
            self.window = window

            NSApp.activate(ignoringOtherApps: true)

            if ResizeSelfTest.isRequested, let resizer {
                DispatchQueue.main.async { ResizeSelfTest.run(window: window, overlay: resizer) }
            }
            if UISelfTest.isRequested {
                UISelfTest.run(window: window, workspace: workspace)
            }
            // Debug hook: select a file + open the inspector, for headless
            // screenshot verification (selection can't be injected from outside).
            // "1" → first non-folder; any other value → first name containing it.
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { workspace?.save(); saveWindowFrame() }
    }

    func applicationDidResignActive(_ notification: Notification) {
        MainActor.assumeIsolated { workspace?.save(); saveWindowFrame() }
    }
}

/// App entry point. Lives in the `anf` library so the logic is unit-testable;
/// the thin `anfapp` executable target just calls this.
public func anfMain() {
    let app = NSApplication.shared
    let controller = AppController()
    app.delegate = controller
    app.setActivationPolicy(.regular)
    MainMenu.install()
    // Keep the delegate alive for the app's lifetime.
    objc_setAssociatedObject(app, "anf.controller", controller, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
