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

    /// Sorted + filtered listing — what the views render. Cached because for big
    /// directories (tens of thousands of entries) re-sorting on every property
    /// read (SwiftUI re-renders, selection math, etc.) is the dominant cost. We
    /// recompute only when `allItems`, `sort` or `filterText` actually change.
    private(set) var items: [FileItem] = []

    /// Bumped whenever `items` changes, so the AppKit table view knows to reload
    /// without diffing the array itself.
    private(set) var itemsVersion = 0

    // Presentation
    var viewMode: ViewMode = .list
    var sort = SortOrder() { didSet { recomputeItems() } }
    var showHidden = false { didSet { reload() } }
    var iconSize: Double = 84
    var textScale: Double = 1.0
    var filterText = "" { didSet { if filterText != oldValue { recomputeItems() } } }
    var inspectorVisible = false
    var sidebarVisible = true

    // Selection — changing it marks this tab/pane as the active one.
    var selection: Set<FileItem.ID> = [] { didSet { onActivity?() } }

    /// Live column count of the icon grid, reported by the view, so ↑/↓ can jump a
    /// whole row instead of stepping one item.
    @ObservationIgnored var gridColumns: Int = 1

    /// Keyboard-selection anchor/cursor indices. Shift-extension grows the
    /// selection from the anchor to the moving cursor — a contiguous run in
    /// list/columns, a rectangle in the icon/gallery grid.
    @ObservationIgnored private var selAnchor: Int?
    @ObservationIgnored private var selCursor: Int?

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
        reload()
    }

    // MARK: - Derived

    /// Rebuild the cached `items` from `allItems` applying the current filter and
    /// sort. The sort uses locale-aware collation which is genuinely expensive for
    /// big Korean-named directories (tens of thousands of entries), so for large
    /// listings it runs off the main thread to keep navigation/scrolling smooth.
    /// Small listings sort inline to avoid a one-frame flicker.
    private func recomputeItems() {
        itemsToken += 1
        let snapshot = allItems
        let filter = filterText
        let order = sort
        let fs = self.fs
        if snapshot.count < 2_000 {
            items = fs.filteredSorted(snapshot, filter: filter, by: order)
            itemsVersion &+= 1
            return
        }
        let token = itemsToken
        Task.detached(priority: .userInitiated) {
            let computed = fs.filteredSorted(snapshot, filter: filter, by: order)
            await MainActor.run { [weak self] in
                guard let self, self.itemsToken == token else { return }
                self.items = computed
                self.itemsVersion &+= 1
            }
        }
    }

    var selectedItems: [FileItem] {
        items.filter { selection.contains($0.id) }
    }

    var canGoBack: Bool { !back.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var canGoUp: Bool { isRemote ? remotePath != "/" : currentURL.path != "/" }

    // MARK: - Remote (SFTP)

    /// True when the current location is a remote `sftp://host/path` address.
    var isRemote: Bool { currentURL.scheme == "sftp" }
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
        var url = URL(fileURLWithPath: "/")
        urls.append(url)
        for part in parts where part != "/" {
            url.appendPathComponent(part)
            urls.append(url)
        }
        return urls
    }

    // MARK: - Navigation

    func navigate(to url: URL, recordHistory: Bool = true) {
        onActivity?()
        guard url != currentURL else { return }
        if recordHistory {
            back.append(currentURL)
            forward.removeAll()
        }
        currentURL = url
        if url.scheme != "sftp" {          // local-only bookkeeping
            RecentFolders.shared.record(url)
            FileIndex.shared.build(for: url)   // pre-index for instant ⌘K filename search
        }
        reload()
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
        forward.append(currentURL)
        currentURL = prev
        reload()
    }

    func goForward() {
        guard let next = forward.popLast() else { return }
        back.append(currentURL)
        currentURL = next
        reload()
    }

    func goUp() {
        guard canGoUp else { return }
        if isRemote, let host = remoteHost {
            let parent = (remotePath as NSString).deletingLastPathComponent
            navigate(to: Self.remoteURL(host: host, path: parent.isEmpty ? "/" : parent))
            return
        }
        navigate(to: currentURL.deletingLastPathComponent())
    }

    // MARK: - Loading

    func reload() {
        loadToken += 1
        let token = loadToken
        let url = currentURL
        let hidden = showHidden
        isLoading = true
        selection.removeAll()
        if isRemote { reloadRemote(token: token); return }
        Task {
            // Single bulk pass: name + type + size + dates for every entry in a
            // few syscalls, no per-item stat. `contentsFast` already carries the
            // metadata the columns need, so there is no slow second pass.
            let loaded = await fs.contentsFast(of: url, showHidden: hidden)
            guard token == loadToken else { return }
            allItems = loaded
            recomputeItems()
            isLoading = false
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
        allItems = allItems.map { $0.url == url ? fresh : $0 }
        recomputeItems()
    }

    // MARK: - Actions

    func trashSelection() {
        let targets = selectedItems
        guard !targets.isEmpty else { return }
        FileOperations.moveToTrash(targets)
        reload()
    }

    func duplicateSelection() {
        FileOperations.duplicate(selectedItems)
        reload()
    }

    func makeNewFolder() {
        if let url = FileOperations.newFolder(in: currentURL) {
            reload()
            // select the new folder once the reload lands
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                selection = [url]
            }
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
    func moveSelection(by delta: Int, extend: Bool = false) {
        let n = items.count
        guard n > 0 else { return }
        // Current cursor: the tracked one if still in sync with the live selection
        // (a click/navigation would desync it), else derived from the selection.
        let current: Int? = {
            if let c = selCursor, c < n, selection.contains(items[c].id) { return c }
            return selection.first.flatMap { id in items.firstIndex { $0.id == id } }
        }()
        let cursor = min(max((current ?? (delta >= 0 ? -1 : n)) + delta, 0), n - 1)

        if !extend {
            selAnchor = cursor
            selCursor = cursor
            selection = [items[cursor].id]
            return
        }
        let anchor = selAnchor ?? (current ?? cursor)
        selAnchor = anchor
        selCursor = cursor
        let grid = (viewMode == .icons || viewMode == .gallery)
        if grid {
            // Rectangle between anchor and cursor (arrow-shaped grid selection).
            let cols = max(1, gridColumns)
            let aR = anchor / cols, aC = anchor % cols
            let cR = cursor / cols, cC = cursor % cols
            let r0 = min(aR, cR), r1 = max(aR, cR), c0 = min(aC, cC), c1 = max(aC, cC)
            var sel = Set<FileItem.ID>()
            for r in r0...r1 {
                for c in c0...c1 {
                    let i = r * cols + c
                    if i < n { sel.insert(items[i].id) }
                }
            }
            selection = sel
        } else {
            let lo = min(anchor, cursor), hi = max(anchor, cursor)
            selection = Set(items[lo...hi].map(\.id))
        }
    }

    func bumpScale(_ direction: Int) {
        if viewMode == .icons {
            iconSize = min(max(iconSize + Double(direction) * 14, 40), 168)
        } else {
            textScale = min(max(textScale + Double(direction) * 0.1, 0.8), 2.0)
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

    func pasteFromPasteboard() {
        let pb = NSPasteboard.general
        guard let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], !urls.isEmpty else { return }
        // A paste of ⌘X-marked items is a move (Finder semantics); the cut mark
        // clears after one paste so repeat-pastes copy.
        if Set(urls.map(\.path)) == Self.cutPaths {
            Self.cutPaths = []
            FileOperations.move(urls, into: currentURL)
        } else {
            FileOperations.copy(urls, into: currentURL)
        }
        reload()
    }

    /// Copy the current selection into another directory (used by Mdir-style
    /// pane-to-pane transfers).
    func copySelection(into destination: URL, move: Bool) {
        let urls = selectedItems.map(\.url)
        guard !urls.isEmpty, destination != currentURL else { return }
        if move { FileOperations.move(urls, into: destination) }
        else { FileOperations.copy(urls, into: destination) }
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
            reload(); selection = [dest]
        }
    }

    /// Legacy modal rename (kept for menu use).
    func renameSelected() {
        guard let item = selectedItems.first else { return }
        guard let newName = TextPrompt.run(title: "Rename", message: "New name for “\(item.name)”",
                                           defaultValue: item.name, action: "Rename") else { return }
        if let dest = FileOperations.rename(item, to: newName) {
            reload(); selection = [dest]
        }
    }

    /// Accept dropped file URLs into `destination` (a folder, or the current dir).
    /// Holding Option copies; default is move — matching Finder same-volume behaviour.
    func acceptDrop(_ urls: [URL], into destination: URL, copy: Bool) {
        let incoming = urls.filter { $0.deletingLastPathComponent().path != destination.path }
        guard !incoming.isEmpty else { return }
        if copy { FileOperations.copy(incoming, into: destination) }
        else { FileOperations.move(incoming, into: destination) }
        reload()
    }

    /// Batch rename the selection by find/replace on each name.
    func batchRename() {
        let targets = selectedItems
        guard targets.count > 1 else { renameSelected(); return }
        guard let (find, replace) = TextPrompt.runPair(
            title: "Rename \(targets.count) Items",
            message: "Replace text in each name:",
            label1: "Find", label2: "Replace with", action: "Rename"),
              !find.isEmpty else { return }
        for item in targets {
            let newName = item.name.replacingOccurrences(of: find, with: replace)
            if newName != item.name { _ = FileOperations.rename(item, to: newName) }
        }
        reload()
    }

    func goToFolderPrompt() {
        guard let raw = TextPrompt.run(title: "Go to Folder",
                                       message: "Enter or paste a path:",
                                       defaultValue: currentURL.path, action: "Go") else { return }
        let expanded = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
            navigate(to: URL(fileURLWithPath: expanded))
        } else {
            NSSound.beep()
        }
    }
}
