import SwiftUI
import AppKit
import Observation

/// The single source of truth for a window: where we are, what's there,
/// what's selected, and how it's presented. Lives on the main actor.
@MainActor
@Observable
final class BrowserModel: Identifiable {
    let id = UUID()

    // Navigation
    private(set) var currentURL: URL
    private(set) var back: [URL] = []
    private(set) var forward: [URL] = []

    // Contents
    private(set) var allItems: [FileItem] = []
    private(set) var isLoading = false
    /// The current folder exists but isn't readable (TCC / POSIX permissions) —
    /// shown instead of a misleading "empty folder".
    private(set) var accessDenied = false
    /// The folder's volume became unreachable mid-session (network mount blipped:
    /// NAS sleep, wifi drop, VPN reconnect). We hold the last listing and auto-retry
    /// instead of blanking + showing a misleading permission error — that flicker is
    /// what users read as "the network drive is unstable".
    private(set) var networkStalled = false

    /// When set, this tab is "locked" to a folder (issue #14): re-selecting the tab
    /// snaps it back here, so it works like a pinned quick-access tab (★). nil =
    /// free tab. Enforced by `PaneModel.activeIndex`.
    var lockedURL: URL?
    var isLocked: Bool { lockedURL != nil }
    /// Lock to the current folder, or unlock if already locked.
    func toggleLock() { lockedURL = isLocked ? nil : currentURL }

    /// Sorted + filtered listing — what the views render. Cached because for big
    /// directories (tens of thousands of entries) re-sorting on every property
    /// read (SwiftUI re-renders, selection math, etc.) is the dominant cost. We
    /// recompute only when `allItems`, `sort` or `filterText` actually change.
    private(set) var items: [FileItem] = []

    /// Bumped whenever `items` changes, so the AppKit table view knows to reload
    /// without diffing the array itself.
    private(set) var itemsVersion = 0

    // MARK: - Inline tree (list mode)
    /// Folders the user expanded inline in list mode. Their children are spliced
    /// into `items` indented, so selection/keyboard/sort all work unchanged.
    @ObservationIgnored private var expanded: Set<URL> = []
    /// Lazily-loaded raw children per expanded folder (sorted per-level on use).
    @ObservationIgnored private var childCache: [URL: [FileItem]] = [:]
    @ObservationIgnored private var childSortedCache: [URL: [FileItem]] = [:]
    @ObservationIgnored private var loadingChildren: Set<URL> = []
    /// The sorted top level (without tree splicing) — cached so expand/collapse
    /// re-flattens WITHOUT re-sorting the whole listing each time.
    @ObservationIgnored private var sortedTop: [FileItem] = []
    /// Indent depth per row URL, rebuilt on every flatten (0 = top level).
    @ObservationIgnored private(set) var rowDepth: [URL: Int] = [:]

    func isExpandable(_ item: FileItem) -> Bool { viewMode == .list && item.isBrowsableContainer }
    func isExpanded(_ item: FileItem) -> Bool { expanded.contains(item.url) }
    func depth(of item: FileItem) -> Int { rowDepth[item.url] ?? 0 }

    /// The expanded folder row that contains this nested row (one level up), or
    /// nil at top level — used by ← to jump to and collapse the parent.
    func parentRow(of item: FileItem) -> FileItem? {
        let d = depth(of: item)
        guard d > 0, let idx = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        var i = idx - 1
        while i >= 0 { if depth(of: items[i]) == d - 1 { return items[i] }; i -= 1 }
        return nil
    }

    /// The nearest expanded folder above this row — so ← keeps closing opened
    /// folders one by one, walking upward.
    func nearestExpandedAbove(of item: FileItem) -> FileItem? {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return nil }
        var i = idx - 1
        while i >= 0 {
            let it = items[i]
            if it.isBrowsableContainer, expanded.contains(it.url) { return it }
            i -= 1
        }
        return nil
    }

    /// Select a single row and keep the keyboard cursor/anchor in sync, so the
    /// next ↑/↓ continues from here (used by ← tree navigation).
    func select(_ item: FileItem) {
        selection = [item.id]
        selCursor = items.firstIndex { $0.id == item.id }
        selAnchor = selCursor
    }

    /// Expand/collapse a folder row inline (list mode). Re-flattens from the
    /// cached sorted top level — no full re-sort, so it stays snappy.
    func toggleExpand(_ item: FileItem) {
        guard isExpandable(item) else { return }
        let collapsing = expanded.contains(item.url)
        if collapsing {
            expanded.remove(item.url)
        } else {
            expanded.insert(item.url)
            if childCache[item.url] == nil { loadChildren(item.url) }
        }
        _ = collapsing
        reflattenTree()
    }

    /// → in list mode: open the selected folder if it's collapsed, otherwise step
    /// the cursor to the next row. Mashing → therefore expands every folder it
    /// lands on and walks the whole tree top-to-bottom — "open everything" on one
    /// key. Returns false (let the native view handle →) only when not applicable.
    @discardableResult
    func expandOrAdvance() -> Bool {
        guard viewMode == .list, let it = selectedItems.first,
              let idx = index(of: it.id) else { return false }
        // Collapsed folder → expand it in place. Children load asynchronously, so
        // the cursor stays put; the next → press (children present by then) dives in.
        if isExpandable(it) && !isExpanded(it) {
            toggleExpand(it)
            return true
        }
        // Expanded but children not spliced in yet → wait here so we don't skip
        // over them to a sibling on the race; the next press lands on the child.
        if isExpandable(it) && isExpanded(it) && childCache[it.url] == nil {
            return true
        }
        // Expanded folder (children present) or a leaf → advance to the next row.
        // For an expanded folder the next row IS its first child (flattenTree
        // splices children right after the parent), so this dives in.
        let next = idx + 1
        guard next < items.count else { return true }   // bottom: keep the cursor put
        select(items[next])
        return true
    }

    /// Rebuild `items` from the cached sorted top + expansions, without sorting.
    private func reflattenTree() {
        if sortedTop.isEmpty { recomputeItems(); return }
        let treeOn = viewMode == .list && !expanded.isEmpty && groupKey == .none
        publishItems(base: sortedTop, treeOn: treeOn)
        repairOrphanedSelection()
    }

    /// If a collapse hid the selected row(s), land the selection on the nearest
    /// surviving ancestor folder so the cursor never vanishes (and ↑ doesn't jump
    /// to the bottom). Works no matter which folder up the chain was collapsed.
    private func repairOrphanedSelection() {
        guard !selection.isEmpty, selectedItems.isEmpty, let lost = selection.first else { return }
        // Match by standardized PATH (URL == is too strict — trailing slash /
        // encoding differ between a folder row and a child's parent URL).
        var u = lost.deletingLastPathComponent()
        while u.path.count > 1 {
            let target = u.standardizedFileURL.path
            if let i = items.firstIndex(where: { $0.url.standardizedFileURL.path == target }) {
                selection = [items[i].id]
                selCursor = i
                selAnchor = i
                return
            }
            u = u.deletingLastPathComponent()
        }
        selCursor = nil; selAnchor = nil   // nothing left → fresh cursor (↑/↓ from top)
    }

    /// Sorted children for a folder (cached; invalidated when sort/filter change).
    private func childSorted(_ url: URL) -> [FileItem]? {
        if let s = childSortedCache[url] { return s }
        guard let raw = childCache[url] else { return nil }
        let s = fs.filteredSorted(raw, filter: filterText, by: sort)
        childSortedCache[url] = s
        return s
    }

    func setExpanded(_ item: FileItem, _ on: Bool) {
        if on == expanded.contains(item.url) { return }
        toggleExpand(item)
    }

    private func loadChildren(_ url: URL) {
        guard !loadingChildren.contains(url) else { return }
        loadingChildren.insert(url)
        let hidden = showHidden
        Task { [weak self] in
            guard let self else { return }
            let kids = await fs.contentsFast(of: url, showHidden: hidden)
            self.childCache[url] = kids
            self.childSortedCache[url] = nil
            self.loadingChildren.remove(url)
            if self.expanded.contains(url) { self.reflattenTree() }
        }
    }

    /// Splice expanded folders' children into the sorted top level, recording
    /// each row's depth. Children are sorted per level with the same order.
    private func flattenTree(_ top: [FileItem]) -> [FileItem] {
        var out: [FileItem] = []
        out.reserveCapacity(top.count)
        var depth: [URL: Int] = [:]
        func walk(_ list: [FileItem], _ d: Int) {
            for it in list {
                depth[it.url] = d
                out.append(it)
                guard it.isBrowsableContainer, expanded.contains(it.url) else { continue }
                if let kids = childSorted(it.url) {
                    walk(kids, d + 1)
                } else {
                    loadChildren(it.url)   // self-heals: re-flattens when loaded
                }
            }
        }
        walk(top, 0)
        rowDepth = depth
        return out
    }

    // Presentation
    /// True while restoring a folder's remembered view mode, so the didSet
    /// doesn't write the restored value back as a user preference.
    @ObservationIgnored private var applyingFolderViewMode = false
    var viewMode: ViewMode = .list {
        didSet {
            guard viewMode != oldValue else { return }
            if viewMode != .list && !expanded.isEmpty { recomputeItems() }  // tree is list-only
            else if viewMode == .list && !expanded.isEmpty { recomputeItems() }
            guard !applyingFolderViewMode else { return }
            ViewModePrefs.shared.set(viewMode, for: currentURL)
        }
    }
    var sort = SortOrder() { didSet { recomputeItems() } }
    /// How the listing is grouped ("Arrange by"). App-wide and persisted; `.none`
    /// is a plain flat list. Grouping disables the expand tree.
    var groupKey: GroupKey = GroupKey(rawValue: UserDefaults.standard.string(forKey: "anf.groupKey") ?? "") ?? .none {
        didSet {
            guard groupKey != oldValue else { return }
            UserDefaults.standard.set(groupKey.rawValue, forKey: "anf.groupKey")
            recomputeItems()
        }
    }
    /// Header ranges for the current grouped `items` (empty when not grouped).
    private(set) var groupRanges: [FileGroup] = []
    /// True while an Arrange-by grouping is active (the views insert headers).
    var grouped: Bool { !groupRanges.isEmpty }
    var showHidden = false { didSet { reload() } }
    /// Icon and text sizes are app-wide preferences: every tab — including ones
    /// created later by splits, Workspace restores or relaunch — starts at the
    /// size the user last chose (⌘±) instead of snapping back to the default.
    var iconSize: Double = UserDefaults.standard.object(forKey: "anf.iconSize") as? Double ?? 84 {
        didSet { UserDefaults.standard.set(iconSize, forKey: "anf.iconSize") }
    }
    var textScale: Double = UserDefaults.standard.object(forKey: "anf.textScale") as? Double ?? 1.0 {
        didSet { UserDefaults.standard.set(textScale, forKey: "anf.textScale") }
    }
    var filterText = "" { didSet { if filterText != oldValue { recomputeItems() } } }
    var inspectorVisible = false
    var sidebarVisible = true

    // Selection — changing it marks this tab/pane as the active one.
    var selection: Set<FileItem.ID> = [] {
        didSet { selectedItemsCache = nil; onActivity?() }
    }

    /// Memoised `selectedItems`. The naive computed property filters the whole
    /// 26k-item listing on EVERY read, and it's read per keystroke and per render
    /// (inspector, path bar status, keyboard). Invalidate on selection/items change.
    @ObservationIgnored private var selectedItemsCache: [FileItem]?

    /// Live column count of the icon grid, reported by the view, so ↑/↓ can jump a
    /// whole row instead of stepping one item.
    @ObservationIgnored var gridColumns: Int = 1

    /// The scroll view currently presenting this tab's listing (list table or
    /// icon grid), reported by the view, so PgUp/PgDn/Home/End can scroll it —
    /// the views aren't reliably first responder with the global key monitor.
    @ObservationIgnored weak var contentScrollView: NSScrollView?

    /// Keyboard-selection anchor/cursor indices. Shift-extension grows the
    /// selection from the anchor to the moving cursor — a contiguous run in
    /// list/columns, a rectangle in the icon/gallery grid.
    @ObservationIgnored private var selAnchor: Int?
    @ObservationIgnored private var selCursor: Int?

    /// The moving end of a keyboard selection, if still in sync with the live
    /// selection — the grid/table scrolls to follow THIS (not the topmost item),
    /// so shift+↓ / shift+PgDn reveal the growing edge.
    var selectionCursorIndex: Int? {
        guard let c = selCursor, c < items.count, selection.contains(items[c].id) else { return nil }
        return c
    }

    /// Called whenever the user interacts here, so the owning pane can become active.
    @ObservationIgnored var onActivity: (() -> Void)?

    /// Opens anf's embedded terminal at a directory (set by the owning pane).
    @ObservationIgnored var onOpenTerminal: ((URL) -> Void)?

    private let fs = FileSystemService()
    private var loadToken = 0
    /// Bumped on every `recomputeItems`; an async sort only commits if still current.
    private var itemsToken = 0

    init(start: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.currentURL = start
        applyFolderViewMode()
        reload()
    }

    /// Restore this folder's remembered view mode — its own setting or the
    /// nearest ancestor's (subfolders follow the parent unless overridden).
    private func applyFolderViewMode() {
        guard let m = ViewModePrefs.shared.mode(for: currentURL), m != viewMode else { return }
        applyingFolderViewMode = true
        viewMode = m
        applyingFolderViewMode = false
    }

    // MARK: - Derived

    /// Rebuild the cached `items` from `allItems` applying the current filter and
    /// sort. The sort uses locale-aware collation which is genuinely expensive for
    /// big Korean-named directories (tens of thousands of entries), so for large
    /// listings it runs off the main thread to keep navigation/scrolling smooth.
    /// Small listings sort inline to avoid a one-frame flicker.
    private func recomputeItems() {
        itemsToken += 1
        // Virtual listings (Recents, smart folders) keep their supplied order —
        // recency for Recents — so they bypass the sort/cache/tree pipeline.
        if isVirtual {
            let filter = filterText
            let filtered = filter.isEmpty ? allItems
                : allItems.filter { $0.name.localizedCaseInsensitiveContains(filter) }
            sortedTop = filtered
            publishItems(base: filtered, treeOn: false)
            return
        }
        let snapshot = allItems
        let filter = filterText
        let order = sort
        let fs = self.fs
        let cacheURL = isRemote ? nil : currentURL
        let hidden = showHidden
        func cache(_ computed: [FileItem]) {
            guard filter.isEmpty, let url = cacheURL else { return }
            ListingCache.shared.put(url: url, hidden: hidden, sort: order,
                                    all: snapshot, sorted: computed)
        }
        // Splice expanded folders' children in (list mode only) AFTER caching the
        // flat sorted list — the cache stays the plain listing; the tree is view
        // state.
        // Grouping (Arrange-by) and the disclosure tree are mutually exclusive.
        let treeOn = viewMode == .list && !expanded.isEmpty && groupKey == .none
        childSortedCache.removeAll(keepingCapacity: true)   // sort/filter may have changed
        if snapshot.count < 2_000 {
            let sorted = fs.filteredSorted(snapshot, filter: filter, by: order)
            cache(sorted)
            sortedTop = sorted
            publishItems(base: sorted, treeOn: treeOn)
            return
        }
        let token = itemsToken
        Task.detached(priority: .userInitiated) {
            let computed = fs.filteredSorted(snapshot, filter: filter, by: order)
            await MainActor.run { [weak self] in
                guard let self, self.itemsToken == token else { return }
                cache(computed)
                self.sortedTop = computed
                self.publishItems(base: computed, treeOn: treeOn)
            }
        }
    }

    /// Publish `base` as the visible `items`, applying grouping (Arrange-by) or the
    /// expand tree. Grouping reorders into buckets and fills `groupRanges`; with no
    /// grouping the flat (optionally tree-flattened) list is used and `groupRanges`
    /// clears. Keyboard navigation always sees the resulting flat `items`.
    private func publishItems(base: [FileItem], treeOn: Bool) {
        if groupKey != .none {
            let g = FileGrouping.group(base, by: groupKey)
            groupRanges = g.groups
            rowDepth = [:]
            items = g.items
        } else {
            groupRanges = []
            items = treeOn ? flattenTree(base) : { rowDepth = [:]; return base }()
        }
        itemsVersion &+= 1
        selectedItemsCache = nil
    }

    var selectedItems: [FileItem] {
        // ALWAYS read the observable inputs BEFORE the cache check: with
        // @Observable, a SwiftUI body only re-renders if it READ the property.
        // Returning the memo on a warm cache skipped `selection`, so whichever
        // view evaluated after another reader warmed the cache registered no
        // dependency at all and went permanently stale (the inspector stopped
        // following arrow-key selection — issue report 2026-06-13).
        let sel = selection
        _ = itemsVersion
        if let cached = selectedItemsCache { return cached }
        let computed = sel.isEmpty ? [] : items.filter { sel.contains($0.id) }
        selectedItemsCache = computed
        return computed
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool {
        if isVirtual { return false }
        return isRemote ? remotePath != "/" : currentURL.path != "/"
    }

    // MARK: - Remote (SFTP)

    /// True when the current location is a remote `sftp://host/path` address.
    var isRemote: Bool { currentURL.scheme == "sftp" }

    // MARK: - Virtual locations (Recents, Smart Folders)

    /// True when the current location is a synthetic `anf://…` listing (Recents,
    /// a smart folder) rather than a real directory.
    var isVirtual: Bool { currentURL.scheme == "anf" }

    /// The "Recents" virtual location — a recency-ordered list of recently opened
    /// files, populated from `RecentFiles`.
    static let recentsURL = URL(string: "anf://recents")!

    /// Human-readable label for any location, used by the tab strip and path bar.
    /// Virtual `anf://` URLs get a friendly name; real folders use the leaf name.
    static func displayName(for url: URL) -> String {
        if url.scheme == "anf" {
            switch url.host {
            case "recents": return L("Recents", "최근")
            case "smartfolder":
                let id = UUID(uuidString: url.lastPathComponent)
                return id.flatMap { SmartFoldersStore.shared.folder(id: $0)?.name }
                    ?? L("Smart Folder", "스마트 폴더")
            default:        return url.host ?? "anf"
            }
        }
        return url.path == "/" ? "Macintosh HD" : url.lastPathComponent
    }

    /// The label shown on a tab chip. A locked tab keeps its LOCKED folder name as
    /// its identity (Windows Commander style) so selecting another tab never
    /// relabels it to wherever it was last browsed; while it's actively browsed to
    /// a different working dir (before it snaps back on re-selection) it shows
    /// "!workingdir" to flag that the pin is temporarily pointing elsewhere. (#12)
    static func tabTitle(current: URL, locked: URL?) -> String {
        func nonEmpty(_ s: String) -> String { s.isEmpty ? "/" : s }
        guard let locked else { return nonEmpty(displayName(for: current)) }
        if current.standardizedFileURL.path != locked.standardizedFileURL.path {
            return "!" + nonEmpty(displayName(for: current))
        }
        return nonEmpty(displayName(for: locked))
    }

    var remoteHost: String? { currentURL.host }
    var remotePath: String { let p = currentURL.path; return p.isEmpty ? "/" : p }
    /// Set while a remote listing fails, so the view can show the reason.
    private(set) var remoteError: String?

    /// Synthetic address for a remote path; reuses the normal navigation/history.
    static func remoteURL(host: String, path: String) -> URL {
        var c = URLComponents()
        c.scheme = "sftp"; c.host = host
        c.path = path.hasPrefix("/") ? path : "/" + path
        return c.url ?? URL(string: "sftp://\(host)/")!
    }

    /// Open a host's home directory in this pane as a browsable remote folder.
    func openRemote(host: String) {
        remoteError = nil
        isLoading = true
        Task { @MainActor in
            let home = await SFTPClient.home(host)
            navigate(to: Self.remoteURL(host: host, path: home))
        }
    }

    /// Breadcrumb trail from root to the current directory. Built forward from
    /// Foundation's path components — walking *up* with deletingLastPathComponent
    /// can fail to reach a fixed point for some URLs and spin forever.
    var pathComponents: [URL] {
        if isVirtual { return [currentURL] }
        if isRemote, let host = remoteHost {
            var urls = [Self.remoteURL(host: host, path: "/")]
            var path = ""
            for part in remotePath.split(separator: "/") {
                path += "/" + part
                urls.append(Self.remoteURL(host: host, path: path))
            }
            return urls
        }
        let parts = currentURL.standardizedFileURL.pathComponents
        var urls: [URL] = []
        // `isDirectory: true` on BOTH builders is deliberate: the no-flag forms stat
        // the filesystem to decide the trailing slash, which on a network path is a
        // main-thread round-trip whose result varies with latency — yielding
        // nondeterministic crumb URLs that churn the path bar's ForEach ids and drop
        // clicks (N-004). Explicit-directory URLs are stat-free and stable.
        var url = URL(fileURLWithPath: "/", isDirectory: true)
        urls.append(url)
        for part in parts where part != "/" {
            url.appendPathComponent(part, isDirectory: true)
            urls.append(url)
        }
        return urls
    }

    /// "23.4 GB available" for the current folder's volume. Computed off the main
    /// thread and stored here: the volume `resourceValues` call blocks the caller
    /// for the mount's full timeout on a stale network share, so reading it during
    /// the path-bar render (every frame) would beachball. Empty for remote folders.
    private(set) var freeSpaceLabel: String = ""

    /// Recompute `freeSpaceLabel` for `currentURL` off the main thread, then publish
    /// it back. Stale-mount-safe: the blocking `resourceValues` runs detached, so
    /// it can hang harmlessly without freezing the UI. Called from `reload()`.
    private func refreshFreeSpace() {
        guard currentURL.isFileURL else { freeSpaceLabel = ""; return }
        let url = currentURL
        Task.detached(priority: .utility) {
            let bytes = (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            await MainActor.run { [weak self] in
                guard let self, self.currentURL == url else { return }
                self.freeSpaceLabel = bytes.map {
                    L("\(Format.bytes($0)) available", "\(Format.bytes($0)) 사용 가능")
                } ?? ""
            }
        }
    }

    // MARK: - Navigation

    func navigate(to url: URL, recordHistory: Bool = true, returningFrom: URL? = nil) {
        onActivity?()
        // Compare by normalized path for local URLs so a trailing-slash/encoding
        // difference (e.g. a path-bar crumb vs the stored currentURL) neither wrongly
        // no-ops nor forces a redundant reload. Remote/virtual URLs compare exactly.
        let alreadyHere = url.isFileURL && currentURL.isFileURL
            ? url.standardizedFileURL.path == currentURL.standardizedFileURL.path
            : url == currentURL
        guard !alreadyHere else { return }
        if recordHistory {
            back.append(currentURL)
            forward.removeAll()
        }
        currentURL = url
        expanded.removeAll(); childCache.removeAll(); rowDepth.removeAll()  // fresh folder = collapsed
        if url.isFileURL {                 // local-only bookkeeping
            RecentFolders.shared.record(url)
            FileIndex.shared.build(for: url)   // pre-index for instant ⌘K filename search
            VisualIndex.shared.build(for: url) // background image classification (resumable)
        }
        applyFolderViewMode()
        reload()
        // Going up to an ancestor → land on the child we came from. Otherwise land
        // with the first row selected so keyboard navigation continues immediately.
        // revealFile and friends overwrite this with their own selection afterwards
        // (this only fills an EMPTY selection).
        if let returningFrom {
            selectReturning(to: url, from: returningFrom)
        } else {
            selectFirstWhenLoaded()
        }
    }

    func open(_ item: FileItem) {
        if isRemote {
            if item.isDirectory {
                navigate(to: item.url)
            } else {
                openRemoteFile(item)
            }
            return
        }
        if item.isBrowsableContainer {
            navigate(to: item.url)
        } else {
            RecentFiles.shared.record(item.url)   // backs the Recents location
            FileOperations.open(item)
        }
    }

    /// Download a remote file to a temp dir, then open it with the default app.
    private func openRemoteFile(_ item: FileItem) {
        guard let host = remoteHost else { return }
        let remotePath = item.url.path
        Task { @MainActor in
            do {
                let local = try await SFTPClient.download(host: host, remotePath: remotePath)
                NSWorkspace.shared.open(local)
            } catch {
                RemoteMount.presentError(error.localizedDescription)
            }
        }
    }

    func goBack() {
        guard let prev = back.popLast() else { return }
        let left = currentURL          // the folder we're leaving
        forward.append(currentURL)
        currentURL = prev
        applyFolderViewMode()
        reload()
        // Returning to an ancestor: land on the child we'd descended into, not the
        // top of the list, so the eye stays where it was.
        selectReturning(to: prev, from: left)
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(currentURL)
        currentURL = next
        applyFolderViewMode()
        reload()
        selectFirstWhenLoaded()
    }

    func goUp() {
        guard canGoUp else { return }
        let left = currentURL
        if isRemote, let host = remoteHost {
            let parent = (remotePath as NSString).deletingLastPathComponent
            navigate(to: Self.remoteURL(host: host, path: parent.isEmpty ? "/" : parent),
                     returningFrom: left)
            return
        }
        navigate(to: currentURL.deletingLastPathComponent(), returningFrom: left)
    }

    /// The direct child of `parent` that lies on the path down to `descendant`,
    /// or nil if `descendant` isn't actually under `parent`.
    private func childOnPath(from parent: URL, toward descendant: URL) -> URL? {
        let p = parent.standardizedFileURL.pathComponents
        let d = descendant.standardizedFileURL.pathComponents
        guard d.count > p.count, Array(d.prefix(p.count)) == p else { return nil }
        return parent.appendingPathComponent(d[p.count])
    }

    /// After returning to `parent`, select the child we came from (`left`); falls
    /// back to the first row if that child isn't in the listing.
    private func selectReturning(to parent: URL, from left: URL) {
        if let child = childOnPath(from: parent, toward: left) {
            selectChildWhenLoaded(child)
        } else {
            selectFirstWhenLoaded()
        }
    }

    /// After an async load lands, put the selection on the first row so keyboard
    /// navigation continues immediately (going up otherwise left nothing focused).
    private func selectFirstWhenLoaded() {
        let token = loadToken
        // Wait for the NEW listing to commit (version bump), not merely for items
        // to be non-empty — the previous folder's items are still in place while
        // the load runs, and selecting one of those ids left an invisible
        // "1 selected" pointing at a row that no longer exists.
        let versionBefore = itemsVersion
        Task { @MainActor in
            for _ in 0..<20 {   // poll up to ~1s; loads are usually <100ms
                guard token == loadToken else { return }   // superseded
                if itemsVersion != versionBefore, let first = items.first {
                    if selection.isEmpty { selection = [first.id] }
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    /// After the new listing commits, select the item matching `child` (and scroll
    /// to it). Falls back to the first row if it isn't present.
    private func selectChildWhenLoaded(_ child: URL) {
        let token = loadToken
        let versionBefore = itemsVersion
        let wanted = child.standardizedFileURL.path
        Task { @MainActor in
            for _ in 0..<20 {
                guard token == loadToken else { return }
                if itemsVersion != versionBefore {
                    if let match = items.first(where: { $0.url.standardizedFileURL.path == wanted }) {
                        selection = [match.id]
                    } else if selection.isEmpty, let first = items.first {
                        selection = [first.id]
                    }
                    return
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
        }
    }

    // MARK: - Loading

    func reload() {
        loadToken += 1
        let token = loadToken
        let url = currentURL
        let hidden = showHidden
        isLoading = true
        FileTags.clearColorCache()   // tags may have changed since last listing
        childCache.removeAll()       // refetch expanded folders' children on reload
        let priorSelection = selection   // restored if this turns out to be a stall
        selection.removeAll()
        refreshFreeSpace()
        if isVirtual { reloadVirtual(token: token); return }
        if isRemote { reloadRemote(token: token); return }
        // Paint the last known listing instantly (no read, no sort) — the fresh
        // bulk read below lands ~100ms later and diff-replaces any change.
        // The cache holds the flat sorted listing; only fast-paint it when not
        // grouped, otherwise an ungrouped flash precedes the regroup.
        if filterText.isEmpty, groupKey == .none,
           let hit = ListingCache.shared.get(url: url, hidden: hidden, sort: sort) {
            allItems = hit.all
            items = hit.sorted
            itemsVersion &+= 1
            selectedItemsCache = nil
        }
        Task {
            // Single bulk pass: name + type + size + dates for every entry in a
            // few syscalls, no per-item stat. `contentsFast` already carries the
            // metadata the columns need, so there is no slow second pass.
            let loaded = await fs.contentsFast(of: url, showHidden: hidden)
            guard token == loadToken else { return }
            // An empty result is ambiguous: genuinely empty, permission-denied, or
            // the volume just went away (network blip). Probe OFF-MAIN — both
            // `fileExists` and `isReadableFile` block on a stale mount and would
            // beachball if run here — to tell them apart.
            if loaded.isEmpty {
                // `canListDirectory` (opendir), not `isDirectory` (stat): a dropped
                // mount's ROOT still stats from cache, so stat would miss a stall at
                // the share root — opendir actually contacts the server.
                let probe = await Task.detached(priority: .utility) { () -> (reachable: Bool, readable: Bool) in
                    (PathProbe.canListDirectory(url.path), FileManager.default.isReadableFile(atPath: url.path))
                }.value
                guard token == loadToken else { return }
                if !probe.reachable {
                    // Volume unreachable → hold the last listing + selection, flag the
                    // stall, and retry until it comes back. Don't wipe `allItems`.
                    networkStalled = true
                    selection = priorSelection
                    selectedItemsCache = nil
                    isLoading = false
                    scheduleStallRetry(token: token)
                    return
                }
                networkStalled = false
                allItems = loaded
                accessDenied = !probe.readable
                recomputeItems()
                isLoading = false
                return
            }
            networkStalled = false
            allItems = loaded
            accessDenied = false
            recomputeItems()
            isLoading = false
        }
    }

    /// While a network mount is stalled, poll cheaply for the volume to come back,
    /// then do a full reload — instead of re-running the ~30s-blocking directory
    /// read every cycle. Backs off 1.5s → 3 → 6 → … → 30s. A new `loadToken`
    /// (user navigated) cancels the chain.
    private func scheduleStallRetry(token: Int, attempt: Int = 0) {
        let secs = min(1.5 * pow(2, Double(attempt)), 30)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            guard token == loadToken, networkStalled else { return }
            let url = currentURL
            // Cheap reachability poll off-main; only pay for a full reload once the
            // volume answers again.
            let back = await Task.detached(priority: .utility) {
                PathProbe.canListDirectory(url.path)
            }.value
            guard token == loadToken, networkStalled else { return }
            if back { reload() }
            else { scheduleStallRetry(token: token, attempt: min(attempt + 1, 5)) }
        }
    }

    /// Load the current remote directory over SFTP and map it onto FileItems.
    private func reloadRemote(token: Int) {
        guard let host = remoteHost else { return }
        let path = remotePath
        let hidden = showHidden
        Task { @MainActor in
            do {
                let entries = try await SFTPClient.list(host: host, path: path)
                guard token == loadToken else { return }
                allItems = entries
                    .filter { hidden || !$0.name.hasPrefix(".") }
                    .map { e in
                        FileItem.remote(
                            url: Self.remoteURL(host: host, path: joinRemote(path, e.name)),
                            name: e.name, isDir: e.isDir, isSymlink: e.isSymlink,
                            size: e.size, modified: e.modified)
                    }
                remoteError = nil
                recomputeItems()
                isLoading = false
            } catch {
                guard token == loadToken else { return }
                allItems = []; recomputeItems()
                remoteError = error.localizedDescription
                isLoading = false
            }
        }
    }

    private func joinRemote(_ base: String, _ name: String) -> String {
        base == "/" ? "/" + name : base + "/" + name
    }

    /// Populate a virtual `anf://…` listing. Recents resolves the recency-ordered
    /// file list (dropping any that no longer exist) into FileItems; the order is
    /// preserved (recomputeItems skips sorting for virtual locations).
    private func reloadVirtual(token: Int) {
        let host = currentURL.host
        Task { @MainActor in
            let built: [FileItem]
            switch host {
            case "recents":
                let urls = RecentFiles.shared.items
                built = await Task.detached(priority: .userInitiated) {
                    let fm = FileManager.default
                    return urls.compactMap { fm.fileExists(atPath: $0.path) ? FileItem(url: $0) : nil }
                }.value
            case "smartfolder":
                let folder = UUID(uuidString: currentURL.lastPathComponent)
                    .flatMap { SmartFoldersStore.shared.folder(id: $0) }
                if let folder {
                    built = await Task.detached(priority: .userInitiated) {
                        SmartFolderQuery.evaluate(folder).compactMap { FileItem(url: $0) }
                    }.value
                } else {
                    built = []
                }
            default:
                built = []
            }
            guard token == loadToken else { return }
            allItems = built
            recomputeItems()
            isLoading = false
        }
    }


    // MARK: - iCloud

    /// Kick off the iCloud download for a placeholder and refresh that one item
    /// in place once the content lands — size and preview update, selection and
    /// scroll position survive (no full reload).
    func downloadFromCloud(_ item: FileItem) {
        guard item.isCloudPlaceholder else { return }
        try? FileManager.default.startDownloadingUbiquitousItem(at: item.url)
        let url = item.url
        let token = loadToken
        Task { @MainActor in
            for _ in 0..<240 {   // poll ~2 min max, every 0.5s
                try? await Task.sleep(nanoseconds: 500_000_000)
                guard token == loadToken else { return }   // navigated away
                let fresh = URL(fileURLWithPath: url.path)   // bypass cached values
                let status = (try? fresh.resourceValues(
                    forKeys: [.ubiquitousItemDownloadingStatusKey]))?
                    .ubiquitousItemDownloadingStatus
                if status == .current || status == .downloaded { break }
            }
            guard token == loadToken else { return }
            refreshItem(at: url)
        }
    }

    /// Re-stat a single entry and swap it into the listing (immutably).
    private func refreshItem(at url: URL) {
        guard let fresh = FileItem(url: URL(fileURLWithPath: url.path)) else { return }
        guard let idx = allItems.firstIndex(where: { $0.url == url }) else { return }
        allItems[idx] = fresh
        recomputeItems()
    }

    // MARK: - Actions

    func trashSelection() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        let folder = currentURL
        // In a Vault, snapshot the current state BEFORE deleting so the files are
        // recoverable from the timeline even after the Trash is emptied — that's the
        // whole Vault promise (V-002). Snapshot off-main (git), then trash.
        // isVault calls FileManager.fileExists twice — blocking on a stall-mounted
        // network folder this can take ~30s on the main thread (BM-001). Run it
        // off-main alongside the snapshot Task.
        let label = L("Before deleting \(targets.count) item(s)", "\(targets.count)개 삭제 전 자동 저장")
        Task { @MainActor in
            let isVault = await Task.detached(priority: .userInitiated) {
                VaultService.isVault(folder)
            }.value
            guard isVault else {
                FileOperations.moveToTrash(targets)
                self.reload()
                self.broadcast(dirs: [folder.standardizedFileURL.path])
                return
            }
            let snapped = await Task.detached(priority: .userInitiated) {
                VaultService.snapshot(at: folder, label: label)
            }.value
            // If the snapshot didn't take AND the tree still has uncommitted changes,
            // the files being deleted may have no recovery point — abort rather than
            // risk an unrecoverable delete (V-002-A, mirrors V-001-A).
            if !snapped {
                let dirty = await Task.detached(priority: .userInitiated) {
                    VaultService.hasUncommittedChanges(at: folder)
                }.value
                if dirty {
                    FileOperations.presentFailures(
                        L("Couldn’t protect before deleting", "삭제 전에 보호하지 못했어요"),
                        [L("The vault couldn’t snapshot the current state, so the delete was cancelled to avoid unrecoverable loss.",
                           "현재 상태를 스냅샷하지 못해, 복구 불가능한 손실을 막기 위해 삭제를 취소했어요.")])
                    return
                }
            }
            FileOperations.moveToTrash(targets)
            reload()
            broadcast(dirs: [folder.standardizedFileURL.path])
        }
    }

    func duplicateSelection() {
        FileOperations.duplicate(selectedItems)
        reload()
        broadcast(dirs: [currentURL.standardizedFileURL.path])
    }

    func makeNewFolder() {
        if let url = FileOperations.newFolder(in: currentURL) {
            reload()
            broadcast(dirs: [currentURL.standardizedFileURL.path])
            // Select the new folder once the reload lands. Use standardizedFileURL
            // so the selection key matches what FastDirRead returns for the same
            // path (avoids mismatch when the raw creation URL differs from the
            // listing URL in case-folding or symlink form — BM-002).
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                selection = [url.standardizedFileURL]
            }
        }
    }

    /// Finder-style Get Info (⌘⌥I) for each selected item (or the current folder
    /// if nothing is selected).
    func showGetInfo() {
        let targets = selectedItems.isEmpty
            ? (FileItem(url: currentURL).map { [$0] } ?? [])
            : selectedItems
        for item in targets.prefix(8) { GetInfoPanel.show(for: item) }
    }

    /// Toggle a colour tag on every selected item, then refresh so the swatch
    /// updates in the list.
    func toggleTag(_ tag: String) {
        for item in selectedItems { FileTags.toggle(tag, on: item.url) }
        reload()
    }

    // MARK: - Vault

    /// Protect a folder with a time-travel Vault (defaults to the open folder).
    func enableVault(_ target: URL? = nil) {
        let url = target ?? currentURL
        VaultWatcher.shared.enable(url) { [weak self] ok in
            if ok { self?.reload() }
            else { FileOperations.presentFailures(
                L("Couldn’t create Vault", "Vault를 만들지 못했습니다"),
                // Not a nag — most Macs already have git. A one-line way out for
                // the rare machine (often a non-developer's) that doesn't.
                [L("Vault needs the system git. Install it by running this in Terminal: xcode-select --install",
                   "Vault에는 시스템 git이 필요합니다. 터미널에서 다음을 실행하면 설치됩니다: xcode-select --install")]) }
        }
    }

    func confirmDisableVault(_ target: URL? = nil) {
        let url = target ?? currentURL
        let alert = NSAlert()
        alert.messageText = L("Turn off Vault for this folder?", "이 폴더의 Vault를 끌까요?")
        alert.informativeText = L("Your files stay. The version history and protection are removed.",
                                  "파일은 그대로 유지됩니다. 버전 히스토리와 보호만 제거됩니다.")
        alert.addButton(withTitle: L("Turn Off", "끄기"))
        alert.addButton(withTitle: L("Cancel", "취소"))
        if alert.runModal() == .alertFirstButtonReturn {
            VaultWatcher.shared.disable(url)
            reload()
        }
    }

    func revealSelection() {
        FileOperations.reveal(selectedItems.isEmpty ? [] : selectedItems)
    }

    func selectAll() { selection = Set(items.map(\.id)) }

    /// Navigate to a file's parent folder and select the file once the listing
    /// lands (used by the ⌘K palette).
    func revealFile(_ url: URL) {
        let parent = url.deletingLastPathComponent()
        if parent.path != currentURL.path { navigate(to: parent) }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 180_000_000)
            if let match = items.first(where: { $0.url.path == url.path }) {
                selection = [match.id]
            }
        }
    }

    // MARK: - Keyboard-driven actions

    func openSelected() {
        if let item = selectedItems.first { open(item) }
        else if let first = items.first { open(first) }
    }

    /// Move the (single) selection up/down the visible list.
    /// `rowJump` marks ↑/↓ in the icon grid (delta == one grid row). When such a
    /// jump would overshoot the grid — e.g. a single row, or the last partial
    /// row — we step to the adjacent item instead, so ↑/↓ still flip through
    /// photos one at a time rather than snapping to the first/last item.
    func moveSelection(by delta: Int, extend: Bool = false, rowJump: Bool = false) {
        let n = items.count
        guard n > 0 else { return }
        // Current cursor: the tracked one if still in sync with the live selection.
        // A click or navigation desyncs it — then re-derive from the selection in
        // listing order (Set iteration order is arbitrary) and drop the stale
        // anchor, so the next shift+arrow extends from where the user clicked.
        let tracked: Int? = {
            if let c = selCursor, c < n, selection.contains(items[c].id) { return c }
            return nil
        }()
        let current = tracked ?? items.firstIndex { selection.contains($0.id) }
        if tracked == nil { selAnchor = current }
        var effective = delta
        if rowJump, !extend, let cur = current, cur + delta < 0 || cur + delta > n - 1 {
            let step = delta > 0 ? 1 : -1          // no row that way → adjacent item
            if cur + step >= 0, cur + step <= n - 1 { effective = step }
        }
        let cursor = min(max((current ?? (effective >= 0 ? -1 : n)) + effective, 0), n - 1)

        if !extend {
            selAnchor = cursor
            selCursor = cursor
            selection = [items[cursor].id]
            return
        }
        let anchor = selAnchor ?? (current ?? cursor)
        selAnchor = anchor
        selCursor = cursor
        if viewMode == .icons {
            // Icon grid: rectangular block with the anchor and cursor as
            // opposite corners (spreadsheet-style). Backtracking shrinks it.
            let cols = max(1, gridColumns)
            let rows = min(anchor / cols, cursor / cols)...max(anchor / cols, cursor / cols)
            let band = min(anchor % cols, cursor % cols)...max(anchor % cols, cursor % cols)
            var sel = Set<FileItem.ID>()
            for r in rows {
                for c in band where r * cols + c < n {
                    sel.insert(items[r * cols + c].id)
                }
            }
            selection = sel
        } else {
            // List/columns/gallery: contiguous reading-order range.
            let lo = min(anchor, cursor), hi = max(anchor, cursor)
            selection = Set(items[lo...hi].map(\.id))
        }
    }

    // MARK: Type-to-select (Finder typeahead)

    @ObservationIgnored private var typeahead = ""
    @ObservationIgnored private var typeaheadDeadline = Date.distantPast
    /// Per-item search keys, rebuilt only when the listing changes — a keystroke
    /// must not re-derive 26k jamo expansions.
    @ObservationIgnored private var typeaheadKeys: [String] = []
    @ObservationIgnored private var typeaheadKeysVersion = -1

    /// Row index for an id in the current listing — O(1) via a map rebuilt once
    /// per listing change. The table/grid selection sync used to scan all items
    /// per selection change (every arrow key in a 26k folder).
    @ObservationIgnored private var idIndexCache: [FileItem.ID: Int] = [:]
    @ObservationIgnored private var idIndexVersion = -1

    func index(of id: FileItem.ID) -> Int? {
        if idIndexVersion != itemsVersion {
            idIndexVersion = itemsVersion
            idIndexCache = Dictionary(items.enumerated().map { ($0.element.id, $0.offset) },
                                      uniquingKeysWith: { a, _ in a })
        }
        return idIndexCache[id]
    }

    /// Lowercased + jamo-expanded keys for the current listing, index-aligned
    /// with `items`. Shared by typeahead and the palette's local filter so the
    /// per-keystroke work is a byte-wise `contains`, never a 26k Unicode
    /// case-fold on the main thread.
    func nameSearchKeys() -> [String] {
        if typeaheadKeysVersion != itemsVersion {
            typeaheadKeysVersion = itemsVersion
            typeaheadKeys = items.map { HangulJamo.searchKey($0.name) }
        }
        return typeaheadKeys
    }

    /// 초성 keys (one lead consonant per syllable, "금융위원회" → "ㄱㅇㅇㅇㅎ"),
    /// index-aligned with `items`. A consonants-only query can never appear in
    /// the full jamo key (vowels interleave), so it matches against these.
    @ObservationIgnored private var choseongKeys: [String] = []
    @ObservationIgnored private var choseongKeysVersion = -1

    func nameChoseongKeys() -> [String] {
        if choseongKeysVersion != itemsVersion {
            choseongKeysVersion = itemsVersion
            choseongKeys = items.map { HangulJamo.choseongKey($0.name) }
        }
        return choseongKeys
    }

    /// Finder's type-to-select: typing jumps the selection to the first item
    /// whose name starts with the typed prefix; quick successive keys accumulate
    /// ("pl" → "playground") and the buffer resets after a short pause. Korean
    /// matches by jamo ("ㅍ" finds "플레이그라운드"). `fallback` is the physical
    /// key's latin letter — under the Korean IME the C key arrives as "ㅊ", and
    /// when that finds no prefix the latin letter is tried so c still hits
    /// "cli". With no prefix match anywhere the alphabetically nearest follower
    /// is selected, like Finder.
    @discardableResult
    func typeSelect(_ typed: String, fallback: String? = nil, now: Date = Date()) -> Bool {
        guard !items.isEmpty else { return false }
        if now > typeaheadDeadline { typeahead = "" }
        typeaheadDeadline = now.addingTimeInterval(0.8)
        _ = nameSearchKeys()

        func select(_ i: Int) {
            selection = [items[i].id]
            selAnchor = i
            selCursor = i
        }
        // Prefix match, preferring what the IME produced over the raw key.
        // A consonants-only buffer also tries the 초성 keys — ㄱㅇㅇ must reach
        // 금융위원회 even though the full jamo key interleaves vowels.
        for candidate in [typed, fallback].compactMap({ $0 }) {
            let buffer = typeahead + candidate
            let query = HangulJamo.searchKey(buffer)
            if let hit = typeaheadKeys.firstIndex(where: { $0.hasPrefix(query) }) {
                typeahead += candidate
                select(hit)
                return true
            }
            // `contains`, not prefix: kr-style names lead with "(부처명)" and
            // nobody types the parenthesis — jump to the first item whose
            // syllable leads contain the typed run.
            if HangulJamo.isChoseongQuery(buffer),
               let hit = nameChoseongKeys().firstIndex(where: { $0.contains(buffer) }) {
                typeahead += candidate
                select(hit)
                return true
            }
        }
        // No prefix anywhere → nearest follower in name order (Finder behaviour).
        typeahead += typed
        let query = HangulJamo.searchKey(typeahead)
        var after: (index: Int, key: String)?
        var last: (index: Int, key: String)?
        for (i, key) in typeaheadKeys.enumerated() {
            if key > query, after == nil || key < after!.key { after = (i, key) }
            if last == nil || key > last!.key { last = (i, key) }
        }
        guard let target = after?.index ?? last?.index else { return false }
        select(target)
        return true
    }

    func bumpScale(_ direction: Int) {
        if viewMode == .icons {
            iconSize = min(max(iconSize + Double(direction) * 14, 40), 168)
        } else {
            // Finder's list view has exactly two text sizes — ⌘+ goes large,
            // ⌘− back to normal. No zoom ladder.
            textScale = direction > 0 ? 1.25 : 1.0
        }
    }

    /// Paths marked by ⌘X — the next paste MOVES them instead of copying.
    private static var cutPaths: Set<String> = []

    func copySelectionToPasteboard() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        Self.cutPaths = []
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
    }

    func cutSelectionToPasteboard() {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        Self.cutPaths = Set(urls.map(\.path))
    }

    func copyPathToPasteboard() {
        let paths = (selectedItems.isEmpty ? [currentURL] : selectedItems.map(\.url)).map(\.path)
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    /// ⌥⇧⌘C — the folder being viewed, regardless of selection (the first row
    /// is auto-selected, so ⌘⌥C alone can practically never reach it).
    func copyCurrentFolderPath() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(currentURL.path, forType: .string)
    }

    func pasteFromPasteboard() {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return }
        // A paste of ⌘X-marked items is a move (Finder semantics); the cut mark
        // clears after one paste so repeat-pastes copy.
        let isCut = Set(urls.map(\.path)) == Self.cutPaths
        if isCut { Self.cutPaths = [] }
        FileTransfer.shared.transfer(urls, into: currentURL, move: isCut) { [weak self] in
            self?.reload()
        }
    }

    /// Copy the current selection into another directory (used by Mdir-style
    /// pane-to-pane transfers). `onDone` runs after the (async) transfer lands —
    /// the destination pane reloads there, not before.
    // MARK: - Cross-tab change broadcast
    //
    // anf has no live folder watcher, so a tab/pane that is *not* the one
    // performing a file op would otherwise go stale (e.g. the source folder after
    // a drag-move into another pane). After an op, broadcast the affected
    // directories; the workspace reloads every OTHER tab/pane showing them.
    static let dirsChangedNote = Notification.Name("anf.dirsChanged")

    private static func notifyDirsChanged(_ dirs: Set<String>, except: UUID) {
        NotificationCenter.default.post(name: dirsChangedNote, object: nil,
                                        userInfo: ["dirs": dirs, "except": except])
    }

    /// Broadcast affected dirs from a NON-model context (undo/redo): no originating
    /// tab to exclude, so EVERY tab/pane showing one of `dirs` reloads.
    static func broadcastDirsChanged(_ dirs: Set<String>) {
        let nonEmpty = dirs.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        NotificationCenter.default.post(name: dirsChangedNote, object: nil, userInfo: ["dirs": nonEmpty])
    }

    private func broadcast(dirs: Set<String>) {
        let nonEmpty = dirs.filter { !$0.isEmpty }
        guard !nonEmpty.isEmpty else { return }
        Self.notifyDirsChanged(nonEmpty, except: id)
    }

    private func parentDirs(of urls: [URL]) -> Set<String> {
        Set(urls.map { $0.deletingLastPathComponent().standardizedFileURL.path })
    }

    func copySelection(into destination: URL, move: Bool, onDone: @escaping () -> Void = {}) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty, destination != currentURL else { return }
        FileTransfer.shared.transfer(urls, into: destination, move: move) { [weak self] in
            guard let self else { onDone(); return }
            self.reload()
            var dirs: Set<String> = [destination.standardizedFileURL.path]
            if move { dirs.formUnion(self.parentDirs(of: urls)) }
            self.broadcast(dirs: dirs)
            onDone()
        }
    }

    func openTerminalHere() {
        let target = selectedItems.first.flatMap { $0.isBrowsableContainer ? $0.url : nil } ?? currentURL
        if let onOpenTerminal { onOpenTerminal(target) }      // embedded terminal
        else { FileOperations.openInTerminal(target) }        // fallback: external
    }

    /// The row currently being renamed inline (Finder-style edit in place). The
    /// content views show an editable field for this item instead of a label.
    var editingItemID: FileItem.ID?

    /// Begin inline rename on the (single) selection.
    func beginRename() {
        guard let item = selectedItems.first else { return }
        editingItemID = item.id
    }

    func cancelRename() { editingItemID = nil }

    /// Commit an inline rename; no-op if the name is unchanged or empty.
    func commitRename(_ item: FileItem, to newName: String) {
        editingItemID = nil
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return }
        if let dest = FileOperations.rename(item, to: trimmed) {
            // standardizedFileURL normalises the URL so it matches the listing entry
            // that FastDirRead will return after reload (BM-002).
            reload(); selection = [dest.standardizedFileURL]
            broadcast(dirs: [currentURL.standardizedFileURL.path])
        }
    }

    /// Legacy modal rename (kept for menu use).
    func renameSelected() {
        guard let item = selectedItems.first else { return }
        guard let newName = TextPrompt.run(title: L("Rename", "이름 변경"), message: L("New name for ‘\(item.name)’:", "‘\(item.name)’의 새 이름:"),
                                           defaultValue: item.name, action: L("Rename", "변경")) else { return }
        if let dest = FileOperations.rename(item, to: newName) {
            reload(); selection = [dest.standardizedFileURL]
        }
    }

    /// Accept dropped file URLs into `destination` (a folder, or the current dir).
    /// Holding Option copies; default is move — matching Finder same-volume behaviour.
    func acceptDrop(_ urls: [URL], into destination: URL, copy: Bool) {
        let incoming = urls.filter { $0.deletingLastPathComponent().path != destination.path }
        guard !incoming.isEmpty else { return }
        FileTransfer.shared.transfer(incoming, into: destination, move: !copy) { [weak self] in
            guard let self else { return }
            self.reload()
            var dirs: Set<String> = [destination.standardizedFileURL.path]
            if !copy { dirs.formUnion(self.parentDirs(of: incoming)) }
            self.broadcast(dirs: dirs)
        }
    }

    /// Batch rename the selection by find/replace on each name.
    func batchRename() {
        let targets = selectedItems
        guard targets.count > 1 else { renameSelected(); return }
        guard let (find, replace) = TextPrompt.runPair(
            title: L("Rename \(targets.count) Items", "\(targets.count)개 항목 이름 변경"),
            message: L("Replace text in each name:", "각 이름에서 찾아 바꿀 텍스트:"),
            label1: L("Find", "찾기"), label2: L("Replace with", "바꾸기"), action: L("Rename", "변경")),
              !find.isEmpty else { return }
        var renamed: [(from: URL, to: URL)] = []
        for item in targets {
            let newName = item.name.replacingOccurrences(of: find, with: replace)
            if newName != item.name,
               let dest = FileOperations.rename(item, to: newName, recordUndo: false) {
                renamed.append((from: item.url, to: dest))
            }
        }
        // One coalesced undo for the whole batch, not one per file (RN-001).
        if !renamed.isEmpty { FileUndo.shared.record(.move(renamed)) }
        reload()
    }

    /// Bumped to ask the path bar to begin inline path editing (⌘L / "Go to
    /// Folder"). The `PathBarView` observes this counter and, on each change,
    /// swaps its breadcrumbs for a focused text field pre-filled with the current
    /// path (issue #14). A counter rather than a Bool so repeated ⌘L always
    /// re-triggers, even if the field is already showing.
    private(set) var pathEditRequests = 0

    /// Trigger the inline path editor. ⌘L, the "Go to Folder…" menu, and a click
    /// on the path bar's empty area all route here.
    func beginPathEdit() { pathEditRequests += 1 }

    /// Navigate to a typed/pasted path (the inline path editor's commit action,
    /// also the old modal prompt's). Validation runs OFF the main thread: a path
    /// on a slow/disconnected network mount makes `fileExists` block for the
    /// mount's full timeout, which would freeze the UI the instant the user hits
    /// Return. Beeps if it isn't a reachable directory.
    func navigateToTypedPath(_ raw: String) {
        let expanded = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard !expanded.isEmpty else { return }
        Task { @MainActor in
            let isDir = await Task.detached(priority: .userInitiated) { () -> Bool in
                var dir: ObjCBool = false
                return FileManager.default.fileExists(atPath: expanded, isDirectory: &dir) && dir.boolValue
            }.value
            if isDir { navigate(to: URL(fileURLWithPath: expanded)) }
            else { NSSound.beep() }
        }
    }

    /// Legacy modal "Go to Folder" prompt, kept as a fallback for headless/edge
    /// cases. The primary path is now the inline editor via `beginPathEdit()`.
    func goToFolderPrompt() {
        guard let raw = TextPrompt.run(title: L("Go to Folder", "폴더로 이동"),
                                       message: L("Enter or paste a path:", "경로를 입력하거나 붙여넣기:"),
                                       defaultValue: currentURL.path, action: L("Go", "이동")) else { return }
        navigateToTypedPath(raw)
    }
}
