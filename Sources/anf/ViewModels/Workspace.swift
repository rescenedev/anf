import SwiftUI
import Observation

// MARK: - Favorites (persisted, zero-config)

/// User-pinned folders, auto-saved to UserDefaults so they survive relaunch
/// with no setup. Stored as plain paths.
@MainActor
@Observable
final class FavoritesStore {
    private(set) var items: [URL]
    private let key = "anf.favorites.v1"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
    }

    func contains(_ url: URL) -> Bool {
        items.contains { $0.path == url.path }
    }

    func toggle(_ url: URL) {
        if contains(url) { remove(url) } else { add(url) }
    }

    func add(_ url: URL) {
        guard !contains(url) else { return }
        items.append(url); persist()
    }

    func remove(_ url: URL) {
        items.removeAll { $0.path == url.path }; persist()
    }

    private func persist() {
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }
}

// MARK: - Pane (a stack of tabs)

/// One on-screen panel: an ordered set of tabs, each its own `BrowserModel`.
@MainActor
@Observable
final class PaneModel: Identifiable {
    let id = UUID()
    private(set) var tabs: [BrowserModel]
    var activeIndex: Int = 0

    /// "Focus my pane" — set by the workspace; propagated to every tab here.
    @ObservationIgnored var onActivity: (() -> Void)? {
        didSet { tabs.forEach { configure($0) } }
    }

    /// "Open the (global) terminal at this folder" — set by the workspace.
    @ObservationIgnored var onRequestTerminal: ((URL) -> Void)? {
        didSet { tabs.forEach { configure($0) } }
    }

    init(start: URL) {
        tabs = [BrowserModel(start: start)]
        tabs.forEach { configure($0) }
    }

    var current: BrowserModel { tabs[min(activeIndex, tabs.count - 1)] }

    private func configure(_ model: BrowserModel) {
        model.onActivity = onActivity
        model.onOpenTerminal = { [weak self] url in self?.onRequestTerminal?(url) }
    }

    func replaceTabs(_ models: [BrowserModel], activeIndex: Int) {
        guard !models.isEmpty else { return }
        models.forEach { configure($0) }
        tabs = models
        self.activeIndex = max(0, min(activeIndex, models.count - 1))
    }

    func newTab(at url: URL? = nil) {
        let target = url ?? current.currentURL
        let tab = BrowserModel(start: target)
        configure(tab)
        tabs.append(tab)
        activeIndex = tabs.count - 1
    }

    func closeTab(_ idx: Int) {
        guard tabs.count > 1, tabs.indices.contains(idx) else { return }
        tabs.remove(at: idx)
        if activeIndex >= tabs.count { activeIndex = tabs.count - 1 }
    }

    func closeCurrent() { closeTab(activeIndex) }

    func select(_ idx: Int) { if tabs.indices.contains(idx) { activeIndex = idx } }

    func cycle(_ delta: Int) {
        guard !tabs.isEmpty else { return }
        activeIndex = (activeIndex + delta + tabs.count) % tabs.count
    }
}

// MARK: - Workspace (layout + panes + favorites)

enum PaneLayout: String, CaseIterable, Identifiable {
    case single, dual, rows, quad
    var id: String { rawValue }
    var count: Int {
        switch self { case .single: 1; case .dual, .rows: 2; case .quad: 4 }
    }
    var symbol: String {
        switch self {
        case .single: "square"
        case .dual:   "rectangle.split.2x1"
        case .rows:   "rectangle.split.1x2"
        case .quad:   "square.grid.2x2"
        }
    }
}

/// Top-level window state: the pane layout, the panes themselves, which pane is
/// focused, and the shared favorites. The active pane's current tab is what the
/// toolbar, sidebar and keyboard all act on.
@MainActor
@Observable
final class WorkspaceModel {
    var panes: [PaneModel]
    var activePane: Int = 0
    var layout: PaneLayout = .single
    var sidebarVisible = true
    var inspectorVisible = false
    var inspectorWidth: CGFloat = 300
    var paletteVisible = false {
        didSet { InputGate.modalActive = paletteVisible }
    }
    let favorites = FavoritesStore()
    let customSSH = CustomSSHStore()
    let savedViews = SavedViewsStore()

    // Split proportions for the pane grid: fraction of width given to the left
    // column (dual/quad) and of height given to the top row (rows/quad).
    var splitRatioH: CGFloat = 0.5
    var splitRatioV: CGFloat = 0.5

    /// Font size for the inspector's plain-text preview (⌘+ / ⌘− adjusts it).
    var previewTextSize: CGFloat = 12.5

    func bumpPreviewTextSize(_ direction: Int) {
        previewTextSize = min(max(previewTextSize + CGFloat(direction), 9), 28)
    }

    // MARK: - Global terminal drawer (one per window, full content width)

    var terminal: TerminalSession?
    var showTerminal = false
    var terminalHeight: CGFloat = 280
    /// True once the user has dragged the divider — stops the auto 1/3-height
    /// default from overriding their chosen height on subsequent opens.
    var terminalHeightUserSet = false

    /// Font size for the terminal (⌘+ / ⌘− when the terminal is focused).
    var terminalFontSize: CGFloat = 13 {
        didSet { terminal?.applyFontSize(terminalFontSize) }
    }

    /// Clamp the drawer height. When `available` (the content height) is known the
    /// drawer may grow up to 80% of it; otherwise a generous absolute cap applies.
    static func clampTerminalHeight(_ h: CGFloat, available: CGFloat? = nil) -> CGFloat {
        let cap = available.map { max(200, $0 * 0.8) } ?? 1400
        return min(max(h, 120), cap)
    }

    func bumpTerminalFontSize(_ direction: Int) {
        terminalFontSize = min(max(terminalFontSize + CGFloat(direction), 8), 24)
        save()
    }

    func openTerminal(at directory: URL) {
        if terminal == nil {
            let s = TerminalSession.shell(at: directory)
            s.applyFontSize(terminalFontSize)
            terminal = s
        }
        showTerminal = true
    }

    func openSSH(_ host: String) {
        if let t = terminal, t.sshHost == host, t.isRunning {
            showTerminal = true; t.focus(); return
        }
        let s = TerminalSession.ssh(host)
        s.applyFontSize(terminalFontSize)
        setTerminal(s)
    }

    func openSSH(_ custom: CustomSSHHost) {
        if let t = terminal, t.sshHost == custom.target, t.isRunning {
            showTerminal = true; t.focus(); return
        }
        let s = TerminalSession.ssh(custom)
        s.applyFontSize(terminalFontSize)
        setTerminal(s)
    }

    /// Open an SFTP session to `host` in the global terminal drawer.
    func openSFTP(_ host: String) {
        let s = TerminalSession.sftp(host)
        s.applyFontSize(terminalFontSize)
        setTerminal(s)
    }

    /// Swap the drawer's session, killing the previous one's PTY child so we don't
    /// leave the old ssh/sftp process running when switching hosts.
    private func setTerminal(_ s: TerminalSession) {
        terminal?.view.terminate()
        terminal = s
        showTerminal = true
    }

    /// Browse `host` over SFTP directly in the active pane (no terminal, no
    /// sshfs/macFUSE) — the remote home opens as a normal folder listing.
    func openRemote(_ host: String) {
        activePaneModel.current.openRemote(host: host)
    }

    /// Mount `host` over SFTP (sshfs) and open it in the active pane, so the
    /// remote filesystem is browsed like a local folder. Requires sshfs.
    func mountSFTP(_ host: String) {
        RemoteMount.shared.mount(host: host) { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let url):
                self.activePaneModel.current.navigate(to: url)
            case .failure(let message):
                RemoteMount.presentError(message)
            }
        }
    }

    /// `available` is the live content width — the inspector may take up to 55%
    /// of it (≈ half the window). Without a measurement only a sanity cap applies.
    static func clampInspectorWidth(_ w: CGFloat, available: CGFloat? = nil) -> CGFloat {
        let cap = available.map { max(320, $0 * 0.55) } ?? 2000
        return min(max(w, 220), cap)
    }

    static func clampSplitRatio(_ r: CGFloat) -> CGFloat {
        min(max(r, 0.15), 0.85)
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        panes = (0..<4).map { _ in PaneModel(start: home) }
        restore()
        wireActivity()
        // Index the focused folder's subtree (not all of home) so the first ⌘K is
        // instant and the scope follows the focused pane.
        FileIndex.shared.build(for: active.currentURL)
        // Debug hook: ANF_LAYOUT=single|dual|rows|quad forces the initial layout
        // (headless visual verification — clicks can't be synthesized here).
        if let forced = ProcessInfo.processInfo.environment["ANF_LAYOUT"],
           let l = PaneLayout(rawValue: forced) {
            layout = l
        }
    }

    /// Make any interaction inside a pane mark it active, so ⌘T / shortcuts target
    /// the pane the user is actually working in.
    private func wireActivity() {
        for (i, pane) in panes.enumerated() {
            pane.onActivity = { [weak self] in
                guard let self else { return }
                self.activePane = i
                FileIndex.shared.build(for: self.active.currentURL)
            }
            pane.onRequestTerminal = { [weak self] url in self?.openTerminal(at: url) }
        }
    }

    // MARK: - Persistence (zero-config: restored automatically on launch)

    private static let stateKey = "anf.workspace.v1"

    private struct TabState: Codable { var path: String; var viewMode: String }
    private struct PaneState: Codable { var tabs: [TabState]; var activeIndex: Int }
    private struct State: Codable {
        var layout: String
        var activePane: Int
        var sidebarVisible: Bool
        var inspectorVisible: Bool
        var inspectorWidth: Double?
        var splitRatioH: Double?
        var splitRatioV: Double?
        var terminalFontSize: Double?
        var panes: [PaneState]
    }

    func save() {
        let fm = FileManager.default
        let state = State(
            layout: layout.rawValue,
            activePane: activePane,
            sidebarVisible: sidebarVisible,
            inspectorVisible: inspectorVisible,
            inspectorWidth: inspectorWidth,
            splitRatioH: splitRatioH,
            splitRatioV: splitRatioV,
            terminalFontSize: terminalFontSize,
            panes: panes.map { pane in
                PaneState(
                    tabs: pane.tabs.map { TabState(path: $0.currentURL.path, viewMode: $0.viewMode.rawValue) },
                    activeIndex: pane.activeIndex
                )
            }
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
        _ = fm
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }
        let fm = FileManager.default

        // Restore the full window arrangement: pane layout (1/2/rows/4) along
        // with per-pane tabs and their view modes below.
        if let l = PaneLayout(rawValue: state.layout) { layout = l }
        sidebarVisible = state.sidebarVisible
        inspectorVisible = state.inspectorVisible
        if let w = state.inspectorWidth {
            inspectorWidth = Self.clampInspectorWidth(CGFloat(w))
        }
        if let r = state.splitRatioH { splitRatioH = Self.clampSplitRatio(CGFloat(r)) }
        if let r = state.splitRatioV { splitRatioV = Self.clampSplitRatio(CGFloat(r)) }
        if let fs = state.terminalFontSize {
            terminalFontSize = min(max(CGFloat(fs), 8), 24)
        }

        for (i, paneState) in state.panes.enumerated() where i < panes.count {
            let validTabs = paneState.tabs.filter {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
            }
            guard !validTabs.isEmpty else { continue }
            let pane = panes[i]
            let models = validTabs.map { ts -> BrowserModel in
                let m = BrowserModel(start: URL(fileURLWithPath: ts.path))
                if let vm = ViewMode(rawValue: ts.viewMode) { m.viewMode = vm }
                return m
            }
            pane.replaceTabs(models, activeIndex: min(paneState.activeIndex, models.count - 1))
        }
        activePane = min(state.activePane, layout.count - 1)
    }

    // MARK: - Saved Views (named window arrangements)

    /// Snapshot the current pane layout + tabs so it can be recalled later.
    func captureSnapshot() -> ViewSnapshot {
        ViewSnapshot(
            layout: layout.rawValue,
            activePane: activePane,
            splitRatioH: Double(splitRatioH),
            splitRatioV: Double(splitRatioV),
            panes: panes.prefix(layout.count).map { pane in
                ViewSnapshot.Pane(
                    tabs: pane.tabs.map {
                        ViewSnapshot.Tab(path: $0.currentURL.path, viewMode: $0.viewMode.rawValue)
                    },
                    activeIndex: pane.activeIndex)
            }
        )
    }

    /// Restore a saved arrangement: layout, split ratios and each pane's tabs.
    func applySnapshot(_ snap: ViewSnapshot) {
        let fm = FileManager.default
        if let l = PaneLayout(rawValue: snap.layout) { layout = l }
        splitRatioH = Self.clampSplitRatio(CGFloat(snap.splitRatioH))
        splitRatioV = Self.clampSplitRatio(CGFloat(snap.splitRatioV))
        for (i, paneState) in snap.panes.enumerated() where i < panes.count {
            let validTabs = paneState.tabs.filter {
                var isDir: ObjCBool = false
                return fm.fileExists(atPath: $0.path, isDirectory: &isDir) && isDir.boolValue
            }
            guard !validTabs.isEmpty else { continue }
            let models = validTabs.map { ts -> BrowserModel in
                let m = BrowserModel(start: URL(fileURLWithPath: ts.path))
                if let vm = ViewMode(rawValue: ts.viewMode) { m.viewMode = vm }
                return m
            }
            panes[i].replaceTabs(models, activeIndex: min(paneState.activeIndex, models.count - 1))
        }
        activePane = min(snap.activePane, layout.count - 1)
        save()
    }

    /// Save the current arrangement under `name`.
    func saveCurrentView(name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        savedViews.add(SavedView(name: trimmed, snapshot: captureSnapshot()))
    }

    /// The saved view currently applied (drives the sidebar selection highlight).
    var activeViewID: UUID?

    func applyView(_ view: SavedView) {
        activeViewID = view.id
        applySnapshot(view.snapshot)
    }

    var activePaneModel: PaneModel { panes[min(activePane, panes.count - 1)] }
    var active: BrowserModel { activePaneModel.current }

    func focusPane(_ i: Int) { if panes.indices.contains(i) { activePane = i } }

    func cyclePane(_ delta: Int) {
        let n = layout.count
        activePane = (activePane + delta + n) % n
    }

    func setLayout(_ l: PaneLayout) {
        layout = l
        if activePane >= l.count { activePane = 0 }
        save()
    }

    /// Close the focused pane: collapse to a single pane showing one of the other
    /// (surviving) panes. No-op in single layout.
    func closeActivePane() {
        guard layout.count > 1 else { NSSound.beep(); return }
        let survivorIdx = (0..<layout.count).first { $0 != activePane } ?? 0
        if survivorIdx != 0 {
            let survivor = panes[survivorIdx]
            panes[0].replaceTabs(survivor.tabs, activeIndex: survivor.activeIndex)
        }
        activePane = 0
        setLayout(.single)
    }

    func toggleFavoriteCurrent() {
        favorites.toggle(active.currentURL)
    }

    func toggleTerminal() {
        if terminal == nil { openTerminal(at: active.currentURL) } else { showTerminal.toggle() }
        // When (re)opening, hand keyboard focus to the terminal. The view is
        // re-inserted by SwiftUI asynchronously, so retry until it's in a window.
        if showTerminal, let t = terminal {
            for delay in [0.0, 0.08, 0.2] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                    if t.view.window != nil { t.focus() }
                }
            }
        }
    }

    /// Mdir-style: copy/move the active pane's selection into the next visible pane.
    func transferToOtherPane(move: Bool) {
        guard layout.count > 1 else { NSSound.beep(); return }
        let src = active
        let destPane = panes[(activePane + 1) % layout.count]
        let dest = destPane.current
        guard dest.currentURL.path != src.currentURL.path else { NSSound.beep(); return }
        src.copySelection(into: dest.currentURL, move: move)
        dest.reload()
        if move { src.reload() }
    }
}
