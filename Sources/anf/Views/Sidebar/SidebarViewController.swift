import AppKit

/// Native sidebar: an `NSOutlineView` source list (no SwiftUI). Sections are
/// collapsible group rows; highlight follows anf's single-highlight rule
/// (Workspace context owns it; otherwise the row matching the current folder).
/// Built with AppKit because SwiftUI's List kept fighting us on hit areas and
/// row behaviors.
@MainActor
final class SidebarViewController: NSViewController, NSOutlineViewDataSource,
                                   NSOutlineViewDelegate {

    // MARK: Node model

    enum Section: String, CaseIterable {
        case favorites, pinned, workspace, smartFolders, locations, ssh
        var title: String {
            switch self {
            case .favorites:    L("Favorites", "즐겨찾기")
            case .pinned:       L("Pinned", "핀")
            case .workspace:    "Workspace"
            case .smartFolders: L("Smart Folders", "스마트 폴더")
            case .locations:    L("Locations", "위치")
            case .ssh:          "SSH"
            }
        }
        var defaultsKey: String { "anf.sidebar.open.\(rawValue)" }
    }

    final class Node {
        enum Kind {
            case header(Section)
            case folder(name: String, symbol: String, url: URL, removable: Bool, ejectable: Bool)
            case workspaceRow(SavedView)
            case smartFolderRow(SmartFolder)
            case sshRow(SSHHost, CustomSSHHost?)
        }
        let kind: Kind
        var children: [Node] = []
        init(_ kind: Kind) { self.kind = kind }
    }

    private let workspace: WorkspaceModel
    private var roots: [Node] = []
    private var outline: NSOutlineView!
    private var locations: [SidebarItem] = []
    private var sshHosts: [SSHHost] = []
    private var didBecomeActiveObserver: NSObjectProtocol?   // removed in deinit (G-004)

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    private var model: BrowserModel { workspace.active }
    private var trashPath: String? {
        FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first?.path
    }

    // MARK: View setup

    override func loadView() {
        let outline = SidebarOutlineView()
        outline.controller = self
        self.outline = outline
        outline.headerView = nil
        outline.floatsGroupRows = false
        outline.rowSizeStyle = .custom
        outline.rowHeight = 26
        outline.indentationPerLevel = 0
        outline.selectionHighlightStyle = .none   // highlight drawn per-row by state
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(rowClicked)
        outline.autoresizesOutlineColumn = false
        outline.intercellSpacing = NSSize(width: 0, height: 2)
        outline.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        outline.setDraggingSourceOperationMask([.copy], forLocal: false)

        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        outline.addTableColumn(col)
        outline.outlineTableColumn = col

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.automaticallyAdjustsContentInsets = true

        // Slight opacity boost over the bare sidebar material (washes out on
        // bright desktops otherwise).
        let tint = NSView()
        tint.wantsLayer = true
        tint.layer?.backgroundColor =
            NSColor.windowBackgroundColor.withAlphaComponent(0.45).cgColor

        let container = NSView()
        for v in [tint, scroll] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
            NSLayoutConstraint.activate([
                v.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                v.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                v.topAnchor.constraint(equalTo: container.topAnchor),
                v.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }
        view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildTree()
        observeStructure()
        observeSelection()
        Task { [weak self] in
            let locs = await Task.detached(priority: .utility) { SidebarBuilder.locations() }.value
            let hosts = await Task.detached(priority: .utility) { SSHConfig.hosts() }.value
            guard let self else { return }
            self.locations = locs
            self.sshHosts = hosts
            self.rebuildTree()
        }
        // Re-scan when anf becomes active: a permission granted while we were in
        // the background (iCloud Drive / Files & Folders) can newly expose
        // folders — pick them up without a relaunch (reported: iCloud missing
        // until restart). favorites() is recomputed inside rebuildTree().
        // Keep the token so deinit can unregister: a block-based observer is RETAINED
        // by NotificationCenter and fires on every app activation forever otherwise —
        // each closed window leaves a stale block doing a background scan (G-004).
        didBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { [weak self] in
                    let locs = await Task.detached(priority: .utility) { SidebarBuilder.locations() }.value
                    guard let self else { return }
                    self.locations = locs
                    self.rebuildTree()
                }
            }
        }
    }

    deinit {
        if let didBecomeActiveObserver { NotificationCenter.default.removeObserver(didBecomeActiveObserver) }
    }

    /// Observation-driven refresh: any tracked model change rebuilds the tree.
    /// Inputs that change the sidebar's STRUCTURE (rows added/removed) — these
    /// need a full rebuildTree.
    private func observeStructure() {
        withObservationTracking {
            _ = workspace.favorites.items
            _ = workspace.savedViews.views
            _ = workspace.smartFolders.folders
            _ = workspace.customSSH.hosts
            _ = workspace.terminals.map(\.isRunning)
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.rebuildTree()
                self.observeStructure()
            }
        }
    }

    /// Inputs that only move the HIGHLIGHT (which row is "current"). Rebuilding
    /// the whole tree on every folder navigation walked all favorites/ws/ssh and
    /// reloaded the outline per arrow-key — now just repaint the visible rows.
    private func observeSelection() {
        withObservationTracking {
            _ = workspace.activeViewID
            _ = workspace.showTerminal
            _ = workspace.activeTerminalIndex
            _ = workspace.active.currentURL
            _ = workspace.activePane
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.refreshHighlights()
                self.observeSelection()
            }
        }
    }

    /// Repaint only the on-screen rows' highlight pills — no tree rebuild, no
    /// reloadData (which would collapse groups and lose scroll position).
    private func refreshHighlights() {
        let rows = outline.rows(in: outline.visibleRect)
        guard rows.length > 0 else { return }
        for row in rows.location ..< rows.location + rows.length {
            guard let node = outline.item(atRow: row) as? Node,
                  let cell = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? SidebarRowCell
            else { continue }
            cell.setHighlighted(isHighlighted(node))
        }
    }

    /// Whether a node is the current highlight target (matches viewFor's logic).
    private func isHighlighted(_ node: Node) -> Bool {
        switch node.kind {
        case .folder(_, _, let url, _, _):
            return workspace.activeViewID == nil
                && url.standardizedFileURL.path == model.currentURL.standardizedFileURL.path
        case .workspaceRow(let view):
            return workspace.activeViewID == view.id
        case .smartFolderRow(let folder):
            return workspace.activeViewID == nil
                && model.currentURL.absoluteString == folder.url.absoluteString
        case .sshRow(let host, _):
            return workspace.showTerminal && workspace.terminal?.sshHost == host.alias
        case .header:
            return false
        }
    }

    // MARK: Tree

    private func rebuildTree() {
        var roots: [Node] = []

        func header(_ s: Section, _ children: [Node]) -> Node? {
            guard !children.isEmpty else { return nil }
            let h = Node(.header(s)); h.children = children; return h
        }

        // "Recents" (recently opened files) leads the Favorites section, mirroring
        // Finder. It's a virtual anf:// location, not a real folder.
        var favChildren: [Node] = [
            Node(.folder(name: L("Recents", "최근"), symbol: "clock",
                         url: BrowserModel.recentsURL, removable: false, ejectable: false))
        ]
        favChildren += SidebarBuilder.favorites().map {
            Node(.folder(name: $0.name, symbol: $0.symbol, url: $0.url,
                         removable: false, ejectable: false))
        }
        roots.append(header(.favorites, favChildren)!)
        if let pinned = header(.pinned, workspace.favorites.items.map {
            Node(.folder(name: $0.lastPathComponent.isEmpty ? $0.path : $0.lastPathComponent,
                         symbol: "star.fill", url: $0, removable: true, ejectable: false))
        }) { roots.append(pinned) }
        if let ws = header(.workspace, workspace.savedViews.views.map {
            Node(.workspaceRow($0))
        }) { roots.append(ws) }
        // Smart Folders always shows its header (even when empty) so the "+" to
        // create the first saved search is reachable.
        let smartHeader = Node(.header(.smartFolders))
        smartHeader.children = workspace.smartFolders.folders.map { Node(.smartFolderRow($0)) }
        roots.append(smartHeader)
        if let locs = header(.locations, locations.map {
            Node(.folder(name: $0.name, symbol: $0.symbol, url: $0.url,
                         removable: false, ejectable: $0.ejectable))
        }) { roots.append(locs) }

        var seen = Set<String>()
        var sshNodes: [Node] = sshHosts.compactMap { h in
            seen.insert(h.alias).inserted ? Node(.sshRow(h, nil)) : nil
        }
        for custom in workspace.customSSH.hosts where seen.insert(custom.target).inserted {
            sshNodes.append(Node(.sshRow(SSHHost(alias: custom.target, hostName: custom.host), custom)))
        }
        let sshHeader = Node(.header(.ssh)); sshHeader.children = sshNodes
        roots.append(sshHeader)

        self.roots = roots
        outline.reloadData()
        for root in roots {
            guard case .header(let s) = root.kind else { continue }
            let open = UserDefaults.standard.object(forKey: s.defaultsKey) as? Bool ?? true
            if open { outline.expandItem(root) } else { outline.collapseItem(root) }
        }
    }

    // MARK: Data source

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? Node)?.children.count ?? roots.count
    }

    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        (item as? Node)?.children[index] ?? roots[index]
    }

    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool {
        if case .header = (item as! Node).kind { return true }
        return false
    }

    func outlineView(_ o: NSOutlineView, isGroupItem item: Any) -> Bool {
        if case .header = (item as! Node).kind { return true }
        return false
    }

    func outlineViewItemDidExpand(_ n: Notification) { persistDisclosure(n, open: true) }
    func outlineViewItemDidCollapse(_ n: Notification) { persistDisclosure(n, open: false) }
    private func persistDisclosure(_ n: Notification, open: Bool) {
        guard let node = n.userInfo?["NSObject"] as? Node,
              case .header(let s) = node.kind else { return }
        UserDefaults.standard.set(open, forKey: s.defaultsKey)
    }

    // MARK: Cells

    func outlineView(_ o: NSOutlineView, viewFor c: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! Node
        switch node.kind {
        case .header(let s):
            let cell = SidebarHeaderCell.make(o)
            cell.configure(title: s.title,
                           showsAdd: s == .ssh || s == .smartFolders,
                           onAdd: { [weak self] in
                               if s == .smartFolders { self?.addSmartFolder() } else { self?.addSSHHost() }
                           })
            return cell

        case .folder(let name, let symbol, let url, _, _):
            let cell = SidebarRowCell.make(o)
            let isTrash = url.path == trashPath
            let highlighted = workspace.activeViewID == nil
                && url.standardizedFileURL.path == model.currentURL.standardizedFileURL.path
            cell.configure(text: name,
                           symbol: isTrash ? "trash" : symbol,
                           tint: .controlAccentColor,
                           highlighted: highlighted, dot: nil)
            return cell

        case .workspaceRow(let view):
            let cell = SidebarRowCell.make(o)
            let symbol = PaneLayout(rawValue: view.snapshot.layout)?.symbol ?? "macwindow"
            cell.configure(text: view.name, symbol: symbol, tint: .controlAccentColor,
                           highlighted: workspace.activeViewID == view.id, dot: nil)
            return cell

        case .smartFolderRow(let folder):
            let cell = SidebarRowCell.make(o)
            let highlighted = workspace.activeViewID == nil
                && model.currentURL.absoluteString == folder.url.absoluteString
            cell.configure(text: folder.name, symbol: "folder.badge.gearshape",
                           tint: .controlAccentColor, highlighted: highlighted, dot: nil)
            return cell

        case .sshRow(let host, _):
            let cell = SidebarRowCell.make(o)
            let session = workspace.terminals.first { $0.sshHost == host.alias }
            let selected = workspace.showTerminal && workspace.terminal?.sshHost == host.alias
            let dot: NSColor? = session == nil ? nil
                : (session!.isRunning ? .systemGreen : NSColor.secondaryLabelColor.withAlphaComponent(0.5))
            cell.configure(text: host.alias, symbol: "terminal", tint: .systemGreen,
                           highlighted: selected, dot: dot)
            cell.toolTip = "ssh \(host.subtitle)"
            return cell
        }
    }

    func outlineView(_ o: NSOutlineView, shouldSelectItem item: Any) -> Bool { false }

    func outlineView(_ o: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        if case .header = (item as! Node).kind { return 24 }
        return 26
    }

    // MARK: Clicks

    @objc private func rowClicked() {
        let row = outline.clickedRow
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return }
        switch node.kind {
        case .header:
            break   // disclosure handles it
        case .folder(_, _, let url, _, _):
            if url.scheme == "anf" {
                model.navigate(to: url)        // virtual location (Recents) — no pin machinery
            } else if NSEvent.modifierFlags.contains(.option) {
                model.navigate(to: url)        // navigate just this pane
            } else {
                // In a split this navigates only the focused pane; from a single
                // pane it may restore the pin's remembered split arrangement.
                workspace.openPinned(url)
            }
        case .workspaceRow(let view):
            workspace.applyView(view)
        case .smartFolderRow(let folder):
            model.navigate(to: folder.url)
        case .sshRow(let host, let custom):
            if let custom { workspace.openSSH(custom) } else { workspace.openSSH(host.alias) }
        }
    }

    // MARK: Context menus

    func menu(forRow row: Int) -> NSMenu? {
        guard row >= 0, let node = outline.item(atRow: row) as? Node else { return nil }
        let menu = NSMenu()
        func add(_ title: String, destructive: Bool = false, _ action: @escaping () -> Void) {
            let mi = NSMenuItem(title: title, action: #selector(MenuTarget.fire), keyEquivalent: "")
            let t = MenuTarget(action); mi.target = t; mi.representedObject = t
            menu.addItem(mi)
        }

        switch node.kind {
        case .header:
            return nil

        case .folder(let name, _, let url, let removable, let ejectable):
            add(L("Open in New Tab", "새 탭으로 열기")) { [weak self] in
                self?.workspace.activePaneModel.newTab(at: url)
            }
            add(L("Open in This Pane", "이 pane에서 열기")) { [weak self] in
                self?.model.navigate(to: url)
            }
            if url.path == trashPath {
                menu.addItem(.separator())
                add(L("Empty Trash…", "휴지통 비우기…")) { [weak self] in
                    ArchiveService.emptyTrash { self?.model.reload() }
                }
            }
            if ejectable {
                menu.addItem(.separator())
                add(L("Eject ‘\(name)’", "‘\(name)’ 추출")) { [weak self] in self?.eject(url, name: name) }
            }
            if removable {
                menu.addItem(.separator())
                add(L("Remove from Sidebar", "사이드바에서 제거")) { [weak self] in
                    self?.workspace.favorites.remove(url)
                }
            }

        case .workspaceRow(let view):
            add(L("Switch to This Layout", "이 레이아웃으로 전환")) { [weak self] in
                self?.workspace.applyView(view)
            }
            add(L("Overwrite with Current Layout", "현재 레이아웃으로 덮어쓰기")) { [weak self] in
                guard let self else { return }
                self.workspace.savedViews.update(id: view.id, snapshot: self.workspace.captureSnapshot())
            }
            add(L("Rename…", "이름 변경…")) { [weak self] in
                guard let self,
                      let name = TextPrompt.run(title: L("Rename Workspace", "Workspace 이름 변경"),
                                                message: "",
                                                defaultValue: view.name,
                                                action: L("Save", "저장")) else { return }
                self.workspace.savedViews.rename(id: view.id, to: name)
            }
            menu.addItem(.separator())
            add(L("Delete", "삭제")) { [weak self] in
                self?.workspace.savedViews.remove(id: view.id)
            }

        case .smartFolderRow(let folder):
            add(L("Edit…", "편집…")) { [weak self] in self?.editSmartFolder(folder) }
            menu.addItem(.separator())
            add(L("Delete", "삭제")) { SmartFoldersStore.shared.remove(id: folder.id) }

        case .sshRow(let host, let custom):
            let target = custom?.target ?? host.alias
            add(L("Open over SFTP", "SFTP로 열기")) { [weak self] in self?.workspace.openRemote(target) }
            add(L("Connect in anf", "anf에서 연결")) { [weak self] in
                if let custom { self?.workspace.openSSH(custom) } else { self?.workspace.openSSH(host.alias) }
            }
            add(L("SFTP (Terminal)", "SFTP (터미널)")) { [weak self] in self?.workspace.openSFTP(target) }
            add(L("Mount over SFTP", "SFTP 마운트해서 열기")) { [weak self] in self?.workspace.mountSFTP(target) }
            add(L("Connect with Ghostty", "Ghostty로 연결")) { TerminalLauncher.ssh(target) }
            if custom != nil {
                menu.addItem(.separator())
                add(L("Remove from Sidebar", "사이드바에서 제거")) { [weak self] in
                    self?.workspace.customSSH.remove(target: host.alias)
                }
            }
        }
        return menu
    }

    // MARK: Drag source (folders out)

    func outlineView(_ o: NSOutlineView, pasteboardWriterForItem item: Any) -> NSPasteboardWriting? {
        if case .folder(_, _, let url, _, _) = (item as! Node).kind { return url as NSURL }
        return nil
    }

    // MARK: Actions

    private func addSSHHost() {
        guard let custom = SSHPrompt.run() else { return }
        workspace.customSSH.add(custom)
    }

    /// Create a saved search scoped to the focused folder (or home if the pane is
    /// on a virtual/remote location), then jump into it.
    private func addSmartFolder() {
        let here = model.currentURL
        let scope = here.isFileURL ? here : FileManager.default.homeDirectoryForCurrentUser
        guard let r = SmartFolderPrompt.run(scopeName: BrowserModel.displayName(for: scope)) else { return }
        let folder = SmartFolder(name: r.name, scopePath: scope.path, rule: r.rule)
        SmartFoldersStore.shared.add(folder)
        model.navigate(to: folder.url)
    }

    private func editSmartFolder(_ folder: SmartFolder) {
        guard let r = SmartFolderPrompt.run(
            scopeName: BrowserModel.displayName(for: URL(fileURLWithPath: folder.scopePath)),
            existing: (folder.name, folder.rule)) else { return }
        SmartFoldersStore.shared.rename(id: folder.id, to: r.name)
        SmartFoldersStore.shared.update(id: folder.id, rule: r.rule)
        if model.currentURL.absoluteString == folder.url.absoluteString { model.reload() }
    }

    private func eject(_ url: URL, name: String) {
        // unmountAndEjectDevice is synchronous and can block for many seconds on a
        // slow/network volume (SMB) — run it off the main thread so the UI never
        // beachballs, then update the sidebar / report failure back on main.
        Task { [weak self] in
            let result: Result<Void, Error> = await Task.detached(priority: .userInitiated) {
                do { try NSWorkspace.shared.unmountAndEjectDevice(at: url); return .success(()) }
                catch { return .failure(error) }
            }.value
            guard let self else { return }
            switch result {
            case .success:
                self.locations = SidebarBuilder.locations()
                self.rebuildTree()
            case .failure(let error):
                FileOperations.presentFailures(
                    L("Could not eject ‘\(name)’", "‘\(name)’을(를) 추출하지 못했습니다"),
                    [error.localizedDescription])
            }
        }
    }
}

/// Outline view that routes right-clicks to the controller's menus.
private final class SidebarOutlineView: NSOutlineView {
    weak var controller: SidebarViewController?
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return controller?.menu(forRow: row(at: point))
    }
}

// MARK: - Cells

/// Section header with an optional "+" accessory (SSH).
final class SidebarHeaderCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("anf.sidebar.header")
    private let title = NSTextField(labelWithString: "")
    private let addButton = NSButton()
    private var onAdd: (() -> Void)?

    static func make(_ table: NSTableView) -> SidebarHeaderCell {
        (table.makeView(withIdentifier: id, owner: nil) as? SidebarHeaderCell) ?? SidebarHeaderCell()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 11, weight: .semibold)
        title.textColor = .tertiaryLabelColor

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.bezelStyle = .inline
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)
        addButton.contentTintColor = .secondaryLabelColor
        addButton.target = self
        addButton.action = #selector(addTapped)

        addSubview(title)
        addSubview(addButton)
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            addButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            addButton.widthAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, showsAdd: Bool, onAdd: @escaping () -> Void) {
        self.title.stringValue = title
        self.addButton.isHidden = !showsAdd
        self.onAdd = onAdd
    }

    @objc private func addTapped() { onAdd?() }
}

/// One sidebar row: icon + name (+ status dot), with the anf highlight pill.
final class SidebarRowCell: NSTableCellView {
    static let id = NSUserInterfaceItemIdentifier("anf.sidebar.row")
    private let pill = NSView()
    private let icon = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private let dotView = NSView()

    static func make(_ table: NSTableView) -> SidebarRowCell {
        (table.makeView(withIdentifier: id, owner: nil) as? SidebarRowCell) ?? SidebarRowCell()
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.id

        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 8
        pill.layer?.cornerCurve = .continuous

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = .init(pointSize: 12, weight: .regular)

        name.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 13)
        name.lineBreakMode = .byTruncatingTail

        dotView.translatesAutoresizingMaskIntoConstraints = false
        dotView.wantsLayer = true
        dotView.layer?.cornerRadius = 3.5

        addSubview(pill)
        addSubview(icon)
        addSubview(name)
        addSubview(dotView)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 18),
            name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            name.trailingAnchor.constraint(lessThanOrEqualTo: dotView.leadingAnchor, constant: -6),
            name.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            dotView.centerYAnchor.constraint(equalTo: centerYAnchor),
            dotView.widthAnchor.constraint(equalToConstant: 7),
            dotView.heightAnchor.constraint(equalToConstant: 7),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(text: String, symbol: String, tint: NSColor,
                   highlighted: Bool, dot: NSColor?) {
        name.stringValue = text
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = tint
        setHighlighted(highlighted)
        dotView.isHidden = dot == nil
        dotView.layer?.backgroundColor = dot?.cgColor
    }

    /// Just the highlight pill — used by the navigation-only refresh that must
    /// not rebuild the whole row.
    func setHighlighted(_ on: Bool) {
        pill.layer?.backgroundColor = on
            ? NSColor.labelColor.withAlphaComponent(0.12).cgColor
            : NSColor.clear.cgColor
    }
}
