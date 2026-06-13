import AppKit

/// Native (AppKit) command palette: a floating panel with a search field and a
/// results table. ⌘K toggles it. Filters favorites + the current folder, and runs
/// a bounded recursive search for 2+ character queries. Return navigates to a
/// folder or reveals a file.
///
/// Built in pure AppKit (no SwiftUI) so first-responder focus, mouse selection
/// and arrow-key navigation all work reliably — the SwiftUI version could not
/// grab keyboard focus inside the AppKit-hosted window.
@MainActor
final class CommandPaletteController: NSObject, NSTextFieldDelegate,
                                      NSTableViewDataSource, NSTableViewDelegate {
    struct Target {
        let name: String
        let url: URL
        let symbol: String
        let isFile: Bool
        var isContent = false   // matched by file content (ripgrep), not name
        var isDivider = false   // non-selectable section header row
        /// When set, activating this row connects to the SSH host instead of
        /// navigating to a URL.
        var sshHost: String? = nil
        /// When set, activating this row applies the saved Workspace.
        var viewID: UUID? = nil

        static func divider(_ title: String) -> Target {
            Target(name: title, url: URL(fileURLWithPath: "/"), symbol: "",
                   isFile: false, isContent: false, isDivider: true)
        }

        static func ssh(_ host: String, subtitle: String) -> Target {
            Target(name: host, url: URL(string: "ssh://\(host)") ?? URL(fileURLWithPath: "/"),
                   symbol: "network", isFile: false, sshHost: host)
        }

        static func workspace(_ view: SavedView) -> Target {
            let symbol = PaneLayout(rawValue: view.snapshot.layout)?.symbol ?? "macwindow"
            return Target(name: view.name,
                          url: URL(fileURLWithPath: "/__workspace__/\(view.id.uuidString)"),
                          symbol: symbol, isFile: false, viewID: view.id)
        }
    }

    private weak var workspace: WorkspaceModel?
    private var panel: PalettePanel?
    private var isShown = false
    private weak var anchorWindow: NSWindow?
    private var field: NSTextField!
    private var table: NSTableView!
    private var results: [Target] = []
    private var deepResults: [Target] = []
    private var deepTask: Task<Void, Never>?
    private var contentTask: Task<Void, Never>?
    private var nameTargets: [Target] = []
    private var contentTargets: [Target] = []
    private var searching = false
    private var contentScanning = false
    private var debounce: DispatchWorkItem?
    private var placeholder: NSTextField!
    private var spinner: NSProgressIndicator!
    private var scanLabel: NSTextField!
    private var footer: NSTextField!
    private var scanTimer: Timer?
    private var scanDirs: [String] = []
    private var scanIdx = 0
    /// SSH hosts (config + custom) cached when the palette opens, so keystrokes
    /// don't re-read ~/.ssh/config.
    private var sshTargets: [Target] = []

    private let panelWidth: CGFloat = 760
    private let rowHeight: CGFloat = 36
    private let fieldHeight: CGFloat = 56
    private let maxVisibleRows = 12

    init(workspace: WorkspaceModel) {
        self.workspace = workspace
        super.init()
    }

    // MARK: - Show / hide

    func toggle() { isShown ? hide() : show() }

    func show() {
        guard !isShown else { return }
        let host = NSApp.keyWindow ?? NSApp.mainWindow
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) }
        guard let host else { return }
        anchorWindow = host
        let panel = panel ?? buildPanel()
        self.panel = panel
        isShown = true
        if let cur = workspace?.active.currentURL { FileIndex.shared.build(for: cur) }

        field.stringValue = ""
        deepResults = []
        loadSSHTargets()
        recompute()
        position(over: host)
        host.addChildWindow(panel, ordered: .above)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
        InputGate.modalActive = true
    }

    func hide() {
        guard isShown else { return }
        isShown = false
        debounce?.cancel()
        deepTask?.cancel()
        contentTask?.cancel()
        stopScanTimer()
        searching = false
        contentScanning = false
        if let panel {
            anchorWindow?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        InputGate.modalActive = false
        anchorWindow?.makeKeyAndOrderFront(nil)
    }

    private func position(over host: NSWindow) {
        guard let panel else { return }
        let h = panel.frame.height
        // Center on the screen the window is on (slightly above true center, like
        // Spotlight) so a large result list has room to breathe.
        let area = (host.screen ?? NSScreen.main)?.visibleFrame ?? host.frame
        let x = area.midX - panelWidth / 2
        let y = area.midY - h / 2 + area.height * 0.06
        panel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: - Build

    private func buildPanel() -> PalettePanel {
        let panel = PalettePanel(
            contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isMovableByWindowBackground = true   // drag the palette by its body
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.onResignKey = { [weak self] in self?.hide() }

        let blur = NSVisualEffectView()
        // Translucent dark vibrancy so the blurred desktop/content shows through.
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.isEmphasized = true
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 16
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor.white.withAlphaComponent(0.08).cgColor
        blur.translatesAutoresizingMaskIntoConstraints = false
        panel.contentView = NSView()
        panel.contentView!.addSubview(blur)
        NSLayoutConstraint.activate([
            blur.leadingAnchor.constraint(equalTo: panel.contentView!.leadingAnchor),
            blur.trailingAnchor.constraint(equalTo: panel.contentView!.trailingAnchor),
            blur.topAnchor.constraint(equalTo: panel.contentView!.topAnchor),
            blur.bottomAnchor.constraint(equalTo: panel.contentView!.bottomAnchor),
        ])

        // Search row: magnifier + text field
        let magnifier = NSImageView(image: NSImage(
            systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            ?? NSImage())
        magnifier.contentTintColor = .secondaryLabelColor
        magnifier.symbolConfiguration = .init(pointSize: 16, weight: .regular)
        magnifier.translatesAutoresizingMaskIntoConstraints = false

        field = NSTextField()
        field.placeholderString = L("Search files & folders…", "파일 · 폴더 검색…")
        field.font = .systemFont(ofSize: 18)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        // Results table
        table = PaletteTableView()
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.rowHeight = rowHeight
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = false
        table.allowsMultipleSelection = false
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked)        // single click navigates
        table.doubleAction = #selector(rowActivated)
        let col = NSTableColumn(identifier: .init("main"))
        col.resizingMask = .autoresizingMask
        table.addTableColumn(col)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        blur.addSubview(magnifier)
        blur.addSubview(field)
        blur.addSubview(separator)
        blur.addSubview(scroll)

        let tableHeight = rowHeight * CGFloat(maxVisibleRows)
        NSLayoutConstraint.activate([
            magnifier.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 18),
            magnifier.centerYAnchor.constraint(equalTo: field.centerYAnchor),
            magnifier.widthAnchor.constraint(equalToConstant: 20),

            field.leadingAnchor.constraint(equalTo: magnifier.trailingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -16),
            // Center the text vertically within the fieldHeight-tall search row
            // (a tall NSTextField top-aligns its text otherwise).
            field.centerYAnchor.constraint(equalTo: blur.topAnchor, constant: fieldHeight / 2),

            separator.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            separator.topAnchor.constraint(equalTo: blur.topAnchor, constant: fieldHeight),

            scroll.leadingAnchor.constraint(equalTo: blur.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: blur.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -8),
            scroll.heightAnchor.constraint(equalToConstant: tableHeight),
        ])

        // Centered status: a spinner + text ("검색 중…" / "결과 없음") shown when
        // there are no rows yet.
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(spinner)

        let placeholder = NSTextField(labelWithString: "")
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(placeholder)
        // Directory path ticker that flickers by while a search runs.
        let scanLabel = NSTextField(labelWithString: "")
        scanLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        scanLabel.textColor = .tertiaryLabelColor
        scanLabel.alignment = .center
        scanLabel.lineBreakMode = .byTruncatingMiddle
        scanLabel.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(scanLabel)

        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            spinner.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 44),
            spinner.widthAnchor.constraint(equalToConstant: 18),
            spinner.heightAnchor.constraint(equalToConstant: 18),
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.topAnchor.constraint(equalTo: spinner.bottomAnchor, constant: 12),
            scanLabel.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            scanLabel.topAnchor.constraint(equalTo: placeholder.bottomAnchor, constant: 8),
            scanLabel.leadingAnchor.constraint(greaterThanOrEqualTo: blur.leadingAnchor, constant: 24),
            scanLabel.trailingAnchor.constraint(lessThanOrEqualTo: blur.trailingAnchor, constant: -24),
        ])
        // Footer ticker: shows the directory being content-scanned (ripgrep) even
        // after filename results are already on screen.
        let footer = NSTextField(labelWithString: "")
        footer.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        footer.textColor = .tertiaryLabelColor
        footer.alignment = .center
        footer.lineBreakMode = .byTruncatingMiddle
        footer.isHidden = true
        footer.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(footer)
        NSLayoutConstraint.activate([
            footer.centerXAnchor.constraint(equalTo: blur.centerXAnchor),
            footer.bottomAnchor.constraint(equalTo: blur.bottomAnchor, constant: -10),
            footer.leadingAnchor.constraint(greaterThanOrEqualTo: blur.leadingAnchor, constant: 24),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: blur.trailingAnchor, constant: -24),
        ])

        self.spinner = spinner
        self.placeholder = placeholder
        self.scanLabel = scanLabel
        self.footer = footer

        panel.setContentSize(NSSize(width: panelWidth,
                                    height: fieldHeight + 1 + 6 + tableHeight + 8))
        return panel
    }

    // MARK: - Results

    private var query: String { field?.stringValue ?? "" }

    /// Build the SSH host list (custom hosts first, then ~/.ssh/config) once per
    /// open. Reading the config off-main keeps the first keystroke snappy.
    private func loadSSHTargets() {
        let custom = workspace?.customSSH.hosts.map { $0.target } ?? []
        var targets: [Target] = custom.map { .ssh($0, subtitle: $0) }
        Task { @MainActor [weak self] in
            let hosts = await Task.detached(priority: .utility) { SSHConfig.hosts() }.value
            var seen = Set(custom)
            for h in hosts where seen.insert(h.alias).inserted {
                targets.append(.ssh(h.alias, subtitle: h.subtitle))
            }
            self?.sshTargets = targets
            if self?.isShown == true { self?.recompute() }
        }
    }

    private func recompute() {
        guard let workspace else { results = []; table?.reloadData(); return }
        let q = query

        if q.isEmpty {
            // Empty state order: pinned → Workspace → recently visited →
            // built-in favorites → SSH.
            var all: [Target] = []
            for u in workspace.favorites.items {
                all.append(.init(name: u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent,
                                 url: u, symbol: "star.fill", isFile: false))
            }
            for v in workspace.savedViews.views {
                all.append(.workspace(v))
            }
            for u in RecentFolders.shared.items {
                all.append(.init(name: u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent,
                                 url: u, symbol: "clock", isFile: false))
            }
            for f in SidebarBuilder.favorites() {
                all.append(.init(name: f.name, url: f.url, symbol: f.symbol, isFile: false))
            }
            var seen = Set<String>()
            var rows = all.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
                          .prefix(40).map { $0 }
            if !sshTargets.isEmpty {
                rows.append(.divider("SSH"))
                rows.append(contentsOf: sshTargets)
            }
            results = rows
        } else {
            // Local candidates (favorites / recents / current folder) — filter
            // these by name or path so only relevant ones show.
            var local: [Target] = []
            for f in SidebarBuilder.favorites() {
                local.append(.init(name: f.name, url: f.url, symbol: f.symbol, isFile: false))
            }
            for u in workspace.favorites.items {
                local.append(.init(name: u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent,
                                   url: u, symbol: "star.fill", isFile: false))
            }
            for u in RecentFolders.shared.items {
                local.append(.init(name: u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent,
                                   url: u, symbol: "clock", isFile: false))
            }
            var filteredLocal = local.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                || $0.url.path.localizedCaseInsensitiveContains(q)
            }
            // Current-folder items: match against the precomputed jamo search
            // keys (shared with typeahead) — a byte-wise `contains`, not a
            // locale-aware case-fold per item. A sparse query used to scan all
            // 26k names with `range(options: .caseInsensitive)` on the main
            // thread every keystroke — a visible typing hitch. As a bonus the
            // jamo keys make 초성 queries (ㄱㅊ) match here too.
            let qKey = HangulJamo.searchKey(q)
            let keys = workspace.active.nameSearchKeys()
            // Consonants-only query (ㄱㅇㅇ) → match syllable LEADS; the full
            // jamo key interleaves vowels so it can never contain such a run.
            let choKeys = HangulJamo.isChoseongQuery(q)
                ? workspace.active.nameChoseongKeys() : nil
            let folderItems = workspace.active.items
            var folderMatches = 0
            for i in keys.indices where keys[i].contains(qKey) || choKeys?[i].contains(q) == true {
                guard i < folderItems.count else { break }
                let item = folderItems[i]
                filteredLocal.append(.init(name: item.name, url: item.url,
                                           symbol: item.isBrowsableContainer ? "folder" : "doc",
                                           isFile: !item.isBrowsableContainer))
                folderMatches += 1
                if folderMatches >= 60 { break }
            }
            // Filename matches first (local + fd/fzf), then a divider, then
            // ripgrep CONTENT matches. deepResults are already matched by the
            // tools — never re-filter them by name/path.
            var seen = Set<String>()
            let nameRows = (filteredLocal + deepResults.filter { !$0.isContent })
                .filter { seen.insert($0.url.standardizedFileURL.path).inserted }
                .prefix(60).map { $0 }
            let contentRows = deepResults.filter { $0.isContent }
                .filter { seen.insert($0.url.standardizedFileURL.path).inserted }
                .prefix(40).map { $0 }
            // Matching Workspaces and SSH hosts surface at the top.
            let workspaceRows = workspace.savedViews.views
                .filter { $0.name.localizedCaseInsensitiveContains(q) }
                .map { Target.workspace($0) }
            let sshRows = sshTargets.filter { $0.name.localizedCaseInsensitiveContains(q) }
            // Two labeled sections: name matches (files/folders) and content matches.
            var rows: [Target] = []
            if !workspaceRows.isEmpty {
                rows.append(.divider("Workspace"))
                rows.append(contentsOf: workspaceRows)
            }
            if !sshRows.isEmpty {
                rows.append(.divider("SSH"))
                rows.append(contentsOf: sshRows)
            }
            if !nameRows.isEmpty {
                rows.append(.divider(L("Files · Folders", "파일 · 폴더")))
                rows.append(contentsOf: nameRows)
            }
            if !contentRows.isEmpty {
                rows.append(.divider(L("Contents", "내용")))
                rows.append(contentsOf: contentRows)
            }
            results = rows
        }
        table?.reloadData()
        selectFirstSelectableRow()
        updatePlaceholder()
    }

    /// Select the first non-divider row.
    private func selectFirstSelectableRow() {
        guard let first = results.firstIndex(where: { !$0.isDivider }) else { return }
        table.selectRowIndexes(IndexSet(integer: first), byExtendingSelection: false)
    }

    /// Show "검색 중…" while a deep search runs, "결과 없음" when it finishes empty,
    /// and nothing when there are results (or the query is empty).
    private func updatePlaceholder() {
        guard let placeholder, let spinner, let scanLabel, let footer else { return }
        let emptyStatus = results.isEmpty && !query.isEmpty
        let centerTicker = emptyStatus && searching
        // Center status (no results yet).
        placeholder.isHidden = !emptyStatus
        if emptyStatus { placeholder.stringValue = searching ? L("Searching…", "검색 중…") : L("No Results", "결과 없음") }
        if centerTicker { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        // Footer ticker (content search still running while results are shown).
        let footerTicker = contentScanning && !results.isEmpty
        footer.isHidden = !footerTicker
        // Run the directory ticker while either status is active.
        if centerTicker || footerTicker {
            startScanTimer()
        } else {
            stopScanTimer()
            scanLabel.stringValue = ""
            footer.stringValue = ""
        }
    }

    // MARK: - Scan animation (directory paths flickering by during a search)

    private func startScanTimer() {
        guard scanTimer == nil, let scanLabel else { return }
        scanTimer = Timer.scheduledTimer(withTimeInterval: 0.035, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.scanDirs.isEmpty else { return }
                self.scanIdx += 5
                let abbr = self.abbreviate(self.scanDirs[self.scanIdx % self.scanDirs.count])
                // Center label only while there are no results; footer only while
                // content-scanning with results already shown.
                let centerActive = self.results.isEmpty && !self.query.isEmpty && self.searching
                let footerActive = self.contentScanning && !self.results.isEmpty
                scanLabel.stringValue = centerActive ? abbr : ""
                self.footer?.stringValue = footerActive ? L("Searching contents  ·  \(abbr)", "내용 검색 중  ·  \(abbr)") : ""
            }
        }
    }

    private func stopScanTimer() {
        scanTimer?.invalidate()
        scanTimer = nil
    }

    /// Shorten a long path for the scanning ticker: keep the last few components.
    private func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        var p = path
        if p.hasPrefix(home) { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/")
        if parts.count > 4 { return ".../" + parts.suffix(3).joined(separator: "/") }
        return p
    }

    /// Deep search, scoped to the focused folder and below. Filenames come from
    /// the in-memory FileIndex (fuzzy-ranked, instant) and are shown FIRST; then
    /// ripgrep matches file contents under a "내용 일치" divider.
    private func startDeepSearch() {
        deepTask?.cancel()
        contentTask?.cancel()
        let q = query
        guard q.count >= 1, let root = workspace?.active.currentURL else {
            searching = false; nameTargets = []; contentTargets = []
            if !deepResults.isEmpty { deepResults = [] }
            return
        }
        searching = true
        contentScanning = false
        nameTargets = []; contentTargets = []
        deepResults = []
        // Scan animation paths: prefer the built index; before it's ready, use the
        // current folder's immediate subfolders so the ticker shows from the first
        // search instead of a bare "검색 중…".
        scanDirs = FileIndex.shared.directories(for: root)
        if scanDirs.isEmpty {
            scanDirs = (workspace?.active.items ?? [])
                .filter { $0.isBrowsableContainer }
                .map { $0.url.path }
        }
        if scanDirs.isEmpty { scanDirs = [root.path] }

        // Cheap COW capture on main (no filtering); the prefix filter + fuzzy run
        // off the main thread so typing never hitches.
        let pool = FileIndex.shared.poolIfCovers(root)
        let rootPath = root.standardizedFileURL.path
        // 1) Filenames — fuzzy-rank the in-memory index off the main thread.
        // If the index isn't ready, fall back to a per-query fd/mdfind/FileManager.
        deepTask = Task { [weak self] in
            let ranked = await Task.detached(priority: .userInitiated) { () -> [URL] in
                func fdFallback() -> [URL] {
                    PaletteSearch.fdNames(root: root, needle: q, cap: 400)
                        ?? PaletteSearch.mdfindNames(root: root, needle: q, cap: 400)
                        ?? PaletteSearch.fmNames(root: root, needle: q, maxDepth: 6, cap: 400)
                }
                if let pool {
                    // Scope to the focused folder by prefix over the pre-lowered
                    // paths (no URL objects, no lowercasing per keystroke).
                    let lowerRoot = FuzzyMatch.normalizeForIndex(rootPath)
                    let prefix = lowerRoot.hasSuffix("/") ? lowerRoot : lowerRoot + "/"
                    var paths: [String] = []
                    var lower: [String] = []
                    paths.reserveCapacity(pool.paths.count)
                    lower.reserveCapacity(pool.paths.count)
                    for i in pool.paths.indices {
                        let lp = pool.lower[i]
                        if lp == lowerRoot || lp.hasPrefix(prefix) {
                            paths.append(pool.paths[i]); lower.append(lp)
                        }
                    }
                    let hits = FuzzyMatch.rankLowered(paths: paths, lowerPaths: lower,
                                                      query: q, limit: 80)
                    // The index can be stale or partial (a broad parent scan that
                    // didn't reach this subtree, or capped). If it yields nothing,
                    // fall back to a live fd scan so name search never comes up dry.
                    if !hits.isEmpty { return hits }
                    return FuzzyMatch.rank(fdFallback(), query: q, limit: 80)
                }
                return FuzzyMatch.rank(fdFallback(), query: q, limit: 80)
            }.value
            guard let self, self.query == q else { return }
            self.nameTargets = ranked.map { Self.target(for: $0, content: false) }
            self.mergeDeep()
            self.startContentSearch(q, root: root)
        }
    }

    /// 2) Contents via ripgrep over the same folder, appended after the divider.
    private func startContentSearch(_ q: String, root: URL) {
        contentScanning = true
        updatePlaceholder()                    // start the footer scan ticker
        contentTask = Task { [weak self] in
            // .utility, not .userInitiated: the extraction sweep can saturate
            // every core for hundreds of ms — at a lower QoS the UI thread
            // always preempts it, so typing stays smooth. Target construction
            // (one stat per hit) also stays off the main thread here.
            let targets = await Task.detached(priority: .utility) { () -> [Target] in
                // ripgrep (text) → mdfind fallback, plus document body extraction.
                let textHits = PaletteSearch.rgContent(root: root, needle: q, cap: 40)
                    ?? PaletteSearch.mdfindContent(root: root, needle: q, cap: 40)
                let docHits = PaletteSearch.docContent(root: root, needle: q, cap: 25)
                // On-device OCR + image classification: text inside screenshots
                // and visual content ("강아지", "음식"). Higher cap — a photo
                // album can legitimately have many matches.
                let imageHits = PaletteSearch.imageContent(root: root, needle: q, cap: 40)
                var seen = Set<String>()
                return (textHits + docHits + imageHits)
                    .filter { seen.insert($0.standardizedFileURL.path).inserted }
                    .map { Self.target(for: $0, content: true) }
            }.value
            guard let self, self.query == q else { return }
            self.contentTargets = targets
            self.searching = false
            self.contentScanning = false
            self.mergeDeep()
        }
    }

    private func mergeDeep() {
        deepResults = nameTargets + contentTargets
        recompute()
    }

    nonisolated private static func target(for url: URL, content: Bool) -> Target {
        let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return Target(
            name: url.lastPathComponent, url: url,
            symbol: content ? "doc.text.magnifyingglass" : (isDir ? "folder" : "doc"),
            isFile: !isDir, isContent: content)
    }

    private func activateSelection() {
        let row = table.selectedRow
        guard results.indices.contains(row), !results[row].isDivider,
              let workspace else { return }
        let t = results[row]
        if let viewID = t.viewID {
            if let v = workspace.savedViews.views.first(where: { $0.id == viewID }) {
                workspace.applyView(v)
            }
        } else if let host = t.sshHost { workspace.openSSH(host) }
        else if t.isFile { workspace.active.revealFile(t.url) }
        else { workspace.active.navigate(to: t.url) }
        hide()
    }

    @objc private func rowClicked() { activateSelection() }   // single click opens
    @objc private func rowActivated() { activateSelection() }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        let hasQuery = !query.isEmpty
        searching = hasQuery
        recompute()                       // local results instantly + placeholder
        debounce?.cancel()
        guard hasQuery else {
            deepTask?.cancel(); contentTask?.cancel()
            nameTargets = []; contentTargets = []
            if !deepResults.isEmpty { deepResults = []; recompute() }
            return
        }
        // Debounce the fd/ripgrep work so we don't spawn one per keystroke.
        let work = DispatchWorkItem { [weak self] in self?.startDeepSearch() }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.13, execute: work)
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.moveDown(_:)):
            move(1); return true
        case #selector(NSResponder.moveUp(_:)):
            move(-1); return true
        case #selector(NSResponder.insertNewline(_:)):
            activateSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)):
            hide(); return true
        default:
            return false
        }
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        var next = table.selectedRow
        // Step in `delta` direction, skipping non-selectable divider rows.
        repeat { next += delta } while results.indices.contains(next) && results[next].isDivider
        guard results.indices.contains(next) else { return }
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    // MARK: - NSTableView

    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let target = results[row]
        if target.isDivider {
            let id = NSUserInterfaceItemIdentifier("divider")
            let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PaletteDividerView)
                ?? PaletteDividerView(identifier: id)
            cell.configure(title: target.name)
            return cell
        }
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? PaletteRowView)
            ?? PaletteRowView(identifier: id)
        cell.configure(with: target)
        return cell
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        !results[row].isDivider
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PaletteRowBackground()
    }
}
