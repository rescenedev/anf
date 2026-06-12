import AppKit

/// Maps each on-screen window to its `WorkspaceModel`, so app-wide singletons
/// (the keyboard monitor, the View menu) can act on whichever window is key
/// instead of a single hard-wired workspace. This is what makes multi-window
/// possible without threading a workspace reference through everything.
@MainActor
enum WindowRegistry {
    private static var map: [ObjectIdentifier: WorkspaceModel] = [:]
    private(set) static var controllers: [AnfWindowController] = []

    static func register(_ controller: AnfWindowController) {
        controllers.append(controller)
        map[ObjectIdentifier(controller.window)] = controller.workspace
    }

    static func deregister(_ controller: AnfWindowController) {
        controllers.removeAll { $0 === controller }
        map.removeValue(forKey: ObjectIdentifier(controller.window))
    }

    /// The workspace of the key (or main) window — what shortcuts and the View
    /// menu should target right now.
    static var current: WorkspaceModel? {
        if let w = NSApp.keyWindow ?? NSApp.mainWindow, let ws = map[ObjectIdentifier(w)] {
            return ws
        }
        return controllers.first?.workspace
    }

    /// The controller of the key (or main) window.
    static var currentController: AnfWindowController? {
        if let w = NSApp.keyWindow ?? NSApp.mainWindow,
           let c = controllers.first(where: { $0.window === w }) {
            return c
        }
        return controllers.first
    }

    static func workspace(for window: NSWindow?) -> WorkspaceModel? {
        guard let window else { return nil }
        return map[ObjectIdentifier(window)]
    }

    static func saveAll() {
        for c in controllers { c.workspace.save() }
    }
}

/// Owns one anf window and its full view stack (split, sidebar, toolbar, resize
/// overlays). Constructing a second one gives a genuine second window with its
/// own independent `WorkspaceModel` — tabs, panes, history and selection are
/// not shared between windows.
@MainActor
final class AnfWindowController: NSObject, NSWindowDelegate {
    let window: NSWindow
    let workspace: WorkspaceModel
    private let toolbarController: WindowToolbarController
    private var splitView: NSSplitView?
    /// This window's command palette — built lazily, dies with the window.
    lazy var palette = CommandPaletteController(workspace: workspace)

    static let frameKey = "anf.window.frame.v2"

    /// `restoreFrame` is true for the first window of a launch (re-use the saved
    /// geometry); later windows cascade so they don't stack exactly.
    init(workspace: WorkspaceModel, restoreFrame: Bool) {
        self.workspace = workspace

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
        self.splitView = split.splitView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "anf"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 720, height: 460)
        window.isOpaque = false
        window.backgroundColor = .clear
        // CRITICAL for multi-window: a programmatic NSWindow defaults to
        // isReleasedWhenClosed=true, so AppKit releases it on close WHILE this
        // controller still strong-refs it — a double free that segfaults inside
        // the close animation. The controller owns the window's lifetime.
        window.isReleasedWhenClosed = false

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

        let inSelfTest = ResizeSelfTest.isRequested || UISelfTest.isRequested
        // Only the first window owns the shared sidebar-width autosave; extra
        // windows inherit the width but don't fight over the key.
        if !inSelfTest, restoreFrame {
            split.splitView.autosaveName = "anf.main.split"
        }

        let toolbarController = WindowToolbarController(workspace: workspace)
        self.toolbarController = toolbarController
        window.toolbar = toolbarController.makeToolbar()
        window.toolbarStyle = .unified
        self.window = window
        super.init()

        placeWindow(restoreFrame: restoreFrame, inSelfTest: inSelfTest)
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        SidebarDividerResizer.install(in: window, splitView: split.splitView)
        WindowEdgeResizer.install(in: window)
        WindowRegistry.register(self)
    }

    private func placeWindow(restoreFrame: Bool, inSelfTest: Bool) {
        func defaultPlacement() {
            window.setContentSize(NSSize(width: 1180, height: 760))
            window.center()
        }
        guard !inSelfTest, restoreFrame,
              let saved = UserDefaults.standard.string(forKey: Self.frameKey) else {
            defaultPlacement()
            if !restoreFrame { window.cascadeTopLeft(from: NSPoint(x: 40, y: 40)) }
            return
        }
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
    }

    func saveFrame() {
        guard !ResizeSelfTest.isRequested, !UISelfTest.isRequested else { return }
        UserDefaults.standard.set(NSStringFromRect(window.frame), forKey: Self.frameKey)
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        workspace.save()
        saveFrame()
        OverlayKeeper.release(for: window)   // tear down per-window observers
        WindowRegistry.deregister(self)
    }

    func windowDidResignKey(_ notification: Notification) {
        workspace.save()
        saveFrame()
    }
}
