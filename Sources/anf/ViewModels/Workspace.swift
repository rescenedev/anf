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

    private let importedKey = "anf.favorites.importedPaths"

    init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
        importFromSettings()
    }

    /// Import a `"favorites": ["~/Code", "/Volumes/x", …]` list from the ⌘,
    /// settings file — handy for migrating a long Finder favorites list to a new
    /// machine. Each path is imported ONCE (tracked in `importedKey`), so a
    /// favorite you later remove in-app won't keep coming back; adding new paths
    /// to the JSON imports just those on next launch.
    /// JSON paths array for the current pins, to paste into the settings file.
    func exportPaths() -> [String] { items.map(\.path) }

    private func importFromSettings() {
        let dict = Keymap.settingsDict(fileAt: Keymap.fileURL)
        // Accept either key; "pinned" matches the sidebar section, "favorites" is
        // the original name.
        let list = ((dict["pinned"] as? [String]) ?? []) + ((dict["favorites"] as? [String]) ?? [])
        guard !list.isEmpty else { return }
        let fm = FileManager.default
        var imported = Set(UserDefaults.standard.stringArray(forKey: importedKey) ?? [])
        var changed = false, importedChanged = false
        for raw in list {
            let path = Self.cleanFavoritePath(raw)
            guard !path.isEmpty, !imported.contains(path) else { continue }
            imported.insert(path); importedChanged = true
            let url = URL(fileURLWithPath: path)
            if fm.fileExists(atPath: path), !contains(url) { items.append(url); changed = true }
        }
        if importedChanged { UserDefaults.standard.set(Array(imported), forKey: importedKey) }
        if changed { persist() }
    }

    /// Normalise a favorites-JSON entry into a usable path: trim whitespace, strip
    /// one layer of surrounding quotes (users sometimes shell-quote a path with
    /// spaces inside the JSON string — issue #31), then expand a leading `~`.
    static func cleanFavoritePath(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count >= 2,
           (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            s = String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return s.isEmpty ? "" : (s as NSString).expandingTildeInPath
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
    var activeIndex: Int = 0 {
        didSet {
            // A locked tab (issue #14) snaps back to its pinned folder whenever it
            // becomes active — selecting/cycling to it returns there even if it was
            // navigated elsewhere meanwhile.
            guard tabs.indices.contains(activeIndex) else { return }
            let tab = tabs[activeIndex]
            if let locked = tab.lockedURL,
               tab.currentURL.standardizedFileURL.path != locked.standardizedFileURL.path {
                tab.navigate(to: locked)
            }
        }
    }

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
    var title: String {
        switch self {
        case .single: L("Single Pane (⌘1)", "단일창 (⌘1)")
        case .dual:   L("Two Panes (⌘2)", "2분할 좌우 (⌘2)")
        case .rows:   L("Two Rows (⌘3)", "2행 상하 (⌘3)")
        case .quad:   L("Four Panes (⌘4)", "4분할 (⌘4)")
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
    /// Bottom status/path bar — hidden by default; 보기 메뉴 / ⌘/ toggles it.
    var pathBarVisible = false
    var inspectorVisible = false
    var inspectorWidth: CGFloat = 300
    var paletteVisible = false {
        didSet { InputGate.modalActive = paletteVisible }
    }
    /// First-launch shortcut cheat sheet (reopenable from the View menu).
    var showWelcome = !UserDefaults.standard.bool(forKey: "anf.welcomed.v1")
    let favorites = FavoritesStore()
    let customSSH = CustomSSHStore()
    let savedViews = SavedViewsStore()
    /// App-wide saved searches (singleton); exposed here so the sidebar can observe
    /// and list them alongside the per-window stores.
    var smartFolders: SmartFoldersStore { .shared }

    // Split proportions for the pane grid: fraction of width given to the left
    // column (dual/quad) and of height given to the top row (rows/quad).
    var splitRatioH: CGFloat = 0.5
    var splitRatioV: CGFloat = 0.5

    /// Font size for the inspector's text previews (markdown/json/plain text/
    /// office bodies). ⌘+ / ⌘− adjusts it while the inspector shows one; the
    /// choice persists across launches. Default leans large — previews are for
    /// reading, not editing.
    var previewTextSize: CGFloat = WorkspaceModel.loadPreviewTextSize() {
        didSet { UserDefaults.standard.set(Double(previewTextSize), forKey: Self.previewTextSizeKey) }
    }
    private static let previewTextSizeKey = "anf.previewTextSize"

    static func loadPreviewTextSize() -> CGFloat {
        let stored = UserDefaults.standard.double(forKey: previewTextSizeKey)
        return stored >= 9 && stored <= 28 ? CGFloat(stored) : 16
    }

    func bumpPreviewTextSize(_ direction: Int) {
        previewTextSize = min(max(previewTextSize + CGFloat(direction), 9), 28)
    }

    // MARK: - Global terminal drawer (one per window, full content width)

    /// Terminal sessions, shown as tabs in the drawer. `terminal` is the active one.
    private(set) var terminals: [TerminalSession] = []
    var activeTerminalIndex = 0
    var terminal: TerminalSession? {
        terminals.indices.contains(activeTerminalIndex) ? terminals[activeTerminalIndex] : nil
    }
    var showTerminal = false
    var terminalHeight: CGFloat = 280
    /// True once the user has dragged the divider — stops the auto 1/3-height
    /// default from overriding their chosen height on subsequent opens.
    var terminalHeightUserSet = false

    /// Font size for the terminal (⌘+ / ⌘− when the terminal is focused).
    var terminalFontSize: CGFloat = 13 {
        didSet { terminals.forEach { $0.applyFontSize(terminalFontSize) } }
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
        // Per-folder: reuse a live local shell started in THIS folder, else open a
        // new tab for it — so each folder tab gets its own terminal (#29).
        let target = directory.standardizedFileURL
        if let i = terminals.firstIndex(where: {
            $0.sshHost == nil && $0.isRunning && $0.startDirectory?.standardizedFileURL == target
        }) {
            activeTerminalIndex = i
        } else {
            addTerminalTab(.shell(at: directory))
        }
        showTerminal = true
    }

    func openSSH(_ host: String) {
        if focusExistingSSHTab(host) { return }
        addTerminalTab(.ssh(host))
        showTerminal = true
    }

    func openSSH(_ custom: CustomSSHHost) {
        if focusExistingSSHTab(custom.target) { return }
        addTerminalTab(.ssh(custom))
        showTerminal = true
    }

    /// Open an SFTP session to `host` in the global terminal drawer.
    func openSFTP(_ host: String) {
        addTerminalTab(.sftp(host))
        showTerminal = true
    }

    /// Sessions live as tabs: opening another host ADDS a tab (the old PTY keeps
    /// running in its own tab) instead of replacing the drawer's only session.
    private func addTerminalTab(_ s: TerminalSession) {
        s.applyFontSize(terminalFontSize)
        terminals.append(s)
        activeTerminalIndex = terminals.count - 1
    }

    private func focusExistingSSHTab(_ host: String) -> Bool {
        guard let i = terminals.firstIndex(where: { $0.sshHost == host && $0.isRunning }) else {
            return false
        }
        activeTerminalIndex = i
        showTerminal = true
        terminals[i].focus()
        return true
    }

    /// Close one terminal tab (kills its PTY). Closing the last hides the drawer.
    func closeTerminal(at index: Int) {
        guard terminals.indices.contains(index) else { return }
        terminals[index].view.terminate()
        terminals.remove(at: index)
        if terminals.isEmpty {
            showTerminal = false
            activeTerminalIndex = 0
        } else if activeTerminalIndex >= terminals.count {
            activeTerminalIndex = terminals.count - 1
        }
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

    /// "60% · 40%" — the split shown in the divider HUD while dragging (issue #12).
    /// The two halves always sum to 100 so rounding never shows e.g. 60% · 41%.
    nonisolated static func splitLabel(_ ratio: CGFloat) -> String {
        let left = Int((ratio * 100).rounded())
        return "\(left)% · \(100 - left)%"
    }

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        panes = (0..<4).map { _ in PaneModel(start: home) }
        restore()
        loadPinSnapshots()
        wireActivity()
        // "previewTextSize" in the ⌘, settings file applies live on reload.
        NotificationCenter.default.addObserver(
            forName: Keymap.previewTextSizeChanged, object: nil, queue: .main
        ) { [weak self] note in
            guard let size = note.object as? CGFloat else { return }
            MainActor.assumeIsolated { self?.previewTextSize = size }
        }
        // A file op (move/trash/rename) in one tab broadcasts the directories it
        // touched; refresh every OTHER tab/pane showing them — anf has no live FS
        // watcher, so a source folder open in another tab would otherwise go stale.
        NotificationCenter.default.addObserver(
            forName: BrowserModel.dirsChangedNote, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      let dirs = note.userInfo?["dirs"] as? Set<String> else { return }
                let except = note.userInfo?["except"] as? UUID
                for pane in self.panes {
                    for tab in pane.tabs where tab.id != except {
                        if dirs.contains(tab.currentURL.standardizedFileURL.path) { tab.reload() }
                    }
                }
            }
        }
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

    private struct TabState: Codable { var path: String; var viewMode: String; var locked: String? }
    private struct PaneState: Codable { var tabs: [TabState]; var activeIndex: Int }
    private struct State: Codable {
        var layout: String
        var activePane: Int
        var sidebarVisible: Bool
        var inspectorVisible: Bool
        var inspectorWidth: Double?
        var pathBarVisible: Bool?
        var splitRatioH: Double?
        var splitRatioV: Double?
        var terminalFontSize: Double?
        var terminalHeight: Double?
        var terminalHeightUserSet: Bool?
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
            pathBarVisible: pathBarVisible,
            splitRatioH: splitRatioH,
            splitRatioV: splitRatioV,
            terminalFontSize: terminalFontSize,
            terminalHeight: Double(terminalHeight),
            terminalHeightUserSet: terminalHeightUserSet,
            // Only visible panes persist: setLayout resets newly revealed panes
            // to the current folder anyway, so saving hidden panes' tabs only
            // resurrects dead listings (a hidden 26k tab cost ~15MB at launch).
            panes: panes.prefix(layout.count).map { pane in
                PaneState(
                    tabs: pane.tabs.map {
                        TabState(path: $0.currentURL.path, viewMode: $0.viewMode.rawValue,
                                 locked: $0.lockedURL?.path)   // persist tab pin (issue #29)
                    },
                    activeIndex: pane.activeIndex
                )
            }
        )
        if let data = try? JSONEncoder().encode(state) {
            UserDefaults.standard.set(data, forKey: Self.stateKey)
        }
        _ = fm
        // Keep the active pin's remembered split in lockstep (layout edits, tab
        // changes, ratio drags all funnel through save), so quitting mid-context
        // still restores the arrangement next launch.
        if let path = activePinPath {
            if layout.count > 1 { pinSnapshots[path] = captureSnapshot() }
            else { pinSnapshots.removeValue(forKey: path) }
            persistPinSnapshots()
        }
    }

    private func restore() {
        guard let data = UserDefaults.standard.data(forKey: Self.stateKey),
              let state = try? JSONDecoder().decode(State.self, from: data) else { return }

        // Restore the full window arrangement: pane layout (1/2/rows/4) along
        // with per-pane tabs and their view modes below.
        if let l = PaneLayout(rawValue: state.layout) { layout = l }
        sidebarVisible = state.sidebarVisible
        inspectorVisible = state.inspectorVisible
        if let w = state.inspectorWidth {
            inspectorWidth = Self.clampInspectorWidth(CGFloat(w))
        }
        if let p = state.pathBarVisible { pathBarVisible = p }
        if let r = state.splitRatioH { splitRatioH = Self.clampSplitRatio(CGFloat(r)) }
        if let r = state.splitRatioV { splitRatioV = Self.clampSplitRatio(CGFloat(r)) }
        if let fs = state.terminalFontSize {
            terminalFontSize = min(max(CGFloat(fs), 8), 24)
        }
        // Terminal drawer height was saved on every divider drag but never restored
        // (issue #29) — it reset to the default each launch. userSet stops the auto
        // 1/3-height default from overriding the user's chosen height.
        if let th = state.terminalHeight { terminalHeight = Self.clampTerminalHeight(CGFloat(th)) }
        if let u = state.terminalHeightUserSet { terminalHeightUserSet = u }

        for (i, paneState) in state.panes.enumerated() where i < layout.count && i < panes.count {
            // `PathProbe` (not `fm.fileExists`): a folder on a now-unreachable
            // network share blocks the main thread for the mount's full timeout,
            // beachballing relaunch when the last folder lived on that share.
            let validTabs = paneState.tabs.filter { PathProbe.isDirectory($0.path) }
            guard !validTabs.isEmpty else { continue }
            let pane = panes[i]
            let models = validTabs.map { ts -> BrowserModel in
                let m = BrowserModel(start: URL(fileURLWithPath: ts.path))
                if let vm = ViewMode(rawValue: ts.viewMode) { m.viewMode = vm }
                if let lp = ts.locked { m.lockedURL = URL(fileURLWithPath: lp) }   // restore tab pin (#29)
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
        if let l = PaneLayout(rawValue: snap.layout) { layout = l }
        splitRatioH = Self.clampSplitRatio(CGFloat(snap.splitRatioH))
        splitRatioV = Self.clampSplitRatio(CGFloat(snap.splitRatioV))
        for (i, paneState) in snap.panes.enumerated() where i < panes.count {
            let validTabs = paneState.tabs.filter { PathProbe.isDirectory($0.path) }
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
        let snap = captureSnapshot()
        // Saving the exact same arrangement twice just highlights the existing
        // Workspace instead of creating a duplicate row.
        if let existing = savedViews.views.first(where: { $0.snapshot == snap }) {
            activeViewID = existing.id
            return
        }
        let view = SavedView(name: trimmed, snapshot: snap)
        savedViews.add(view)
        // The window currently *is* this arrangement — make it the active context.
        activeViewID = view.id
    }

    /// The Workspace (saved view) currently providing the window's arrangement —
    /// drives the sidebar highlight. This is a *context*, not a location: it stays
    /// active while the user navigates panes/tabs inside it, and clears only when
    /// the structure changes (another Workspace applied, or the layout edited).
    var activeViewID: UUID?

    func applyView(_ view: SavedView) {
        rememberPinContext()
        activePinPath = nil
        activeViewID = view.id
        applySnapshot(view.snapshot)
    }

    /// One-deep backup of the last multi-pane arrangement, captured whenever a
    /// layout change collapses panes. Restored via 보기 → 마지막 분할 배치 복원.
    @ObservationIgnored private var lastSplitBackup: ViewSnapshot?

    func restoreLastSplit() {
        guard let snap = lastSplitBackup else { NSSound.beep(); return }
        activeViewID = nil
        applySnapshot(snap)
    }

    var hasLastSplitBackup: Bool { lastSplitBackup != nil }

    // MARK: - Pinned-folder split memory

    /// The pinned folder the window is currently "in" (set by openPinned). While
    /// set, every save() keeps that pin's arrangement up to date, so pin A →
    /// split & arrange → pin B → pin A restores A's split exactly.
    @ObservationIgnored private var activePinPath: String?
    /// Last multi-pane arrangement per pinned folder, persisted across launches.
    /// Single-pane contexts are intentionally NOT remembered: a pin click is a
    /// plain "go there" unless the user split while inside it.
    @ObservationIgnored private var pinSnapshots: [String: ViewSnapshot] = [:]
    private static let pinSnapshotsKey = "anf.pinSnapshots.v1"

    private func loadPinSnapshots() {
        guard let data = UserDefaults.standard.data(forKey: Self.pinSnapshotsKey),
              let decoded = try? JSONDecoder().decode([String: ViewSnapshot].self, from: data)
        else { return }
        pinSnapshots = decoded
    }

    private func persistPinSnapshots() {
        if let data = try? JSONEncoder().encode(pinSnapshots) {
            UserDefaults.standard.set(data, forKey: Self.pinSnapshotsKey)
        }
    }

    /// Record (or forget) the arrangement of the pin context being left: a split
    /// is worth coming back to; collapsing to a single pane dissolves it.
    private func rememberPinContext() {
        guard let path = activePinPath else { return }
        if layout.count > 1 { pinSnapshots[path] = captureSnapshot() }
        else { pinSnapshots.removeValue(forKey: path) }
        persistPinSnapshots()
    }

    var activePaneModel: PaneModel { panes[min(activePane, panes.count - 1)] }
    var active: BrowserModel { activePaneModel.current }

    func focusPane(_ i: Int) { if panes.indices.contains(i) { activePane = i } }

    func cyclePane(_ delta: Int) {
        let n = layout.count
        activePane = (activePane + delta + n) % n
    }

    /// Sidebar folder click. In a SPLIT layout it navigates only the focused
    /// pane (issue #3: people park a network drive in one pane and browse local
    /// folders in the other — a click must never clobber the opposite pane).
    /// In single layout, a pin that had a split going restores that whole
    /// arrangement; otherwise it just navigates.
    func openPinned(_ url: URL) {
        if layout.count > 1 {
            // Pure navigation: leave the pin-context machinery alone so the
            // current context keeps tracking this (still-live) arrangement.
            active.navigate(to: url)
            return
        }
        rememberPinContext()
        activePinPath = nil   // cleared during the transition so save() can't
                              // stamp the old pin with the new arrangement
        let path = url.standardizedFileURL.path
        if let snap = pinSnapshots[path] {
            // This pin had a split going — bring the whole arrangement back.
            activeViewID = nil
            applySnapshot(snap)
        } else {
            active.navigate(to: url)
        }
        activePinPath = path
    }

    func setLayout(_ l: PaneLayout) {
        // Editing the layout by hand leaves the saved Workspace's arrangement —
        // drop the context highlight. (applySnapshot sets `layout` directly, so
        // applying a Workspace doesn't pass through here.)
        activeViewID = nil
        let oldCount = layout.count
        let here = active.currentURL
        // Shrinking discards a hand-built arrangement — keep one automatic
        // backup so an accidental ⌘1 isn't destructive (보기 → 복원).
        if l.count < oldCount, oldCount > 1 {
            lastSplitBackup = captureSnapshot()
        }
        layout = l
        // Splitting starts every newly revealed pane at the folder being split
        // (not whatever stale tabs it held), so 1→4 shows four copies of the
        // current directory; the user then arranges each pane and saves the
        // result as a Workspace. Panes that were already visible keep theirs.
        if l.count > oldCount {
            for i in oldCount..<min(l.count, panes.count) {
                // Reuse the pane's existing model when it already shows `here` —
                // a fresh BrowserModel forces SwiftUI to rebuild that pane's
                // table view, which is the entire cost of ⌘1–4 on big folders.
                if panes[i].tabs.count == 1, panes[i].current.currentURL == here { continue }
                panes[i].replaceTabs([BrowserModel(start: here)], activeIndex: 0)
            }
        }
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
            let movedTabs = survivor.tabs
            let movedIdx = survivor.activeIndex
            panes[0].replaceTabs(movedTabs, activeIndex: movedIdx)
            // The survivor slot just handed its live BrowserModel instances to
            // pane 0 — it must NOT keep referencing them, or a later split reuses
            // this hidden pane and the two panes share one model and move in
            // lockstep (#50). Reset it to a fresh, independent model.
            let folder = movedTabs[min(movedIdx, movedTabs.count - 1)].currentURL
            survivor.replaceTabs([BrowserModel(start: folder)], activeIndex: 0)
        }
        activePane = 0
        setLayout(.single)
    }

    func toggleFavoriteCurrent() {
        favorites.toggle(active.currentURL)
    }

    /// What ⌃` should do, factored out so it's unit-testable without a live PTY.
    /// ⌃` is folder-aware: hide only when the visible active tab is a local shell
    /// for the CURRENT folder; otherwise surface this folder's local shell. So it
    /// opens a terminal for the current folder even when an SSH/SFTP tab or a
    /// different folder's terminal is showing, instead of just toggling the drawer
    /// (#29) — previously it never gave the current folder a shell.
    enum TerminalToggle: Equatable { case hide, showLocal }
    static func terminalToggleAction(showing: Bool, activeIsLocalShellForCurrentFolder: Bool) -> TerminalToggle {
        (showing && activeIsLocalShellForCurrentFolder) ? .hide : .showLocal
    }

    func toggleTerminal() {
        let here = active.currentURL.standardizedFileURL
        let activeIsLocalHere = terminal != nil && terminal?.sshHost == nil
            && terminal?.startDirectory?.standardizedFileURL == here
        switch Self.terminalToggleAction(showing: showTerminal,
                                         activeIsLocalShellForCurrentFolder: activeIsLocalHere) {
        case .hide:      showTerminal = false
        case .showLocal: openTerminal(at: active.currentURL)   // focus/create this folder's shell
        }
        // When (re)opening, hand keyboard focus to the terminal. The view is
        // re-inserted by SwiftUI asynchronously, so retry until it's in a window.
        if showTerminal, let t = terminal {
            // Retry until the view lands in a window, but STOP once focused —
            // an unconditional 3-shot stole focus back if the user toggled the
            // terminal off within 0.2s.
            func tryFocus(_ remaining: [Double]) {
                guard showTerminal, terminal === t else { return }
                if t.view.window != nil { t.focus(); return }
                guard let next = remaining.first else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + next) {
                    tryFocus(Array(remaining.dropFirst()))
                }
            }
            tryFocus([0.0, 0.08, 0.2])
        }
    }

    /// Mdir-style: copy/move the active pane's selection into the next visible pane.
    func transferToOtherPane(move: Bool) {
        guard layout.count > 1 else { NSSound.beep(); return }
        let src = active
        let destPane = panes[(activePane + 1) % layout.count]
        let dest = destPane.current
        guard dest.currentURL.path != src.currentURL.path else { NSSound.beep(); return }
        src.copySelection(into: dest.currentURL, move: move) { dest.reload() }
    }
}
