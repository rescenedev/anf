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

        static func divider(_ title: String) -> Target {
            Target(name: title, url: URL(fileURLWithPath: "/"), symbol: "",
                   isFile: false, isContent: false, isDivider: true)
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
    private var searching = false
    private var placeholder: NSTextField!

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

        field.stringValue = ""
        deepResults = []
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
        deepTask?.cancel()
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
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.onResignKey = { [weak self] in self?.hide() }

        let blur = NSVisualEffectView()
        blur.material = .menu
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 14
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true
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
        field.placeholderString = "Search files & folders…"
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
        table = NSTableView()
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
        table.action = #selector(rowClicked)
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

        // Centered status text ("검색 중…" / "결과 없음") shown when no rows.
        let placeholder = NSTextField(labelWithString: "")
        placeholder.font = .systemFont(ofSize: 15)
        placeholder.textColor = .secondaryLabelColor
        placeholder.alignment = .center
        placeholder.isHidden = true
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 40),
        ])
        self.placeholder = placeholder

        panel.setContentSize(NSSize(width: panelWidth,
                                    height: fieldHeight + 1 + 6 + tableHeight + 8))
        return panel
    }

    // MARK: - Results

    private var query: String { field?.stringValue ?? "" }

    private func recompute() {
        guard let workspace else { results = []; table?.reloadData(); return }
        let q = query

        if q.isEmpty {
            // Empty state order: pinned → recently visited → built-in favorites.
            var all: [Target] = []
            for u in workspace.favorites.items {
                all.append(.init(name: u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent,
                                 url: u, symbol: "star.fill", isFile: false))
            }
            for u in RecentFolders.shared.items {
                all.append(.init(name: u.lastPathComponent.isEmpty ? u.path : u.lastPathComponent,
                                 url: u, symbol: "clock", isFile: false))
            }
            for f in SidebarBuilder.favorites() {
                all.append(.init(name: f.name, url: f.url, symbol: f.symbol, isFile: false))
            }
            var seen = Set<String>()
            results = all.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
                         .prefix(40).map { $0 }
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
            for item in workspace.active.items {
                local.append(.init(name: item.name, url: item.url,
                                   symbol: item.isBrowsableContainer ? "folder" : "doc",
                                   isFile: !item.isBrowsableContainer))
            }
            let filteredLocal = local.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                || $0.url.path.localizedCaseInsensitiveContains(q)
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
            var rows = Array(nameRows)
            if !contentRows.isEmpty {
                rows.append(.divider("내용 일치"))
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
        guard let placeholder else { return }
        if !results.isEmpty || query.isEmpty {
            placeholder.isHidden = true
        } else {
            placeholder.isHidden = false
            placeholder.stringValue = searching ? "검색 중…" : "결과 없음"
        }
    }

    private func startDeepSearch() {
        deepTask?.cancel()
        let q = query
        guard q.count >= 2, let root = workspace?.active.currentURL else {
            searching = false
            if !deepResults.isEmpty { deepResults = [] }
            return
        }
        searching = true
        deepTask = Task { [weak self] in
            let found = await Task.detached(priority: .userInitiated) {
                PaletteSearch.scan(root: root, needle: q)
            }.value
            guard !Task.isCancelled, let self else { return }
            // Ignore stale results if the query changed meanwhile.
            if self.query == q {
                self.searching = false
                self.deepResults = found
                self.recompute()
            }
        }
    }

    private func activateSelection() {
        let row = table.selectedRow
        guard results.indices.contains(row), !results[row].isDivider,
              let workspace else { return }
        let t = results[row]
        if t.isFile { workspace.active.revealFile(t.url) }
        else { workspace.active.navigate(to: t.url) }
        hide()
    }

    @objc private func rowClicked() { /* selection only; activate on Return/double-click */ }
    @objc private func rowActivated() { activateSelection() }

    // MARK: - NSTextFieldDelegate

    func controlTextDidChange(_ obj: Notification) {
        startDeepSearch()   // sets `searching` before we render the placeholder
        recompute()
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

// MARK: - Panel (borderless windows must opt into key status)

private final class PalettePanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - Divider row ("내용 일치" section header)

private final class PaletteDividerView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) { label.stringValue = title }
}

// MARK: - Row view (icon + name + path)

private final class PaletteRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.alignment = .right
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        addSubview(icon); addSubview(title); addSubview(subtitle)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with t: CommandPaletteController.Target) {
        icon.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
        title.stringValue = t.name
        subtitle.stringValue = t.url.deletingLastPathComponent().path
    }
}

/// Rounded accent highlight for the selected row.
private final class PaletteRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 0)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

/// Recursive search used by the palette. Uses optional CLI tools when present —
/// `fd` for fast/deep filename matching, `ripgrep` for file *content* matching,
/// `fzf` for fuzzy ranking — and falls back to a bounded FileManager walk when
/// none are installed. anf works either way; the tools just make it faster and
/// add content search.
enum PaletteSearch {
    static func scan(root: URL, needle: String, maxDepth: Int = 4,
                     cap: Int = 120) -> [CommandPaletteController.Target] {
        var results: [CommandPaletteController.Target] = []
        var seen = Set<String>()

        func add(_ url: URL, content: Bool) {
            let key = url.standardizedFileURL.path
            guard seen.insert(key).inserted, results.count < cap else { return }
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            results.append(.init(
                name: url.lastPathComponent, url: url,
                symbol: content ? "doc.text.magnifyingglass" : (isDir ? "folder" : "doc"),
                isFile: !isDir, isContent: content))
        }

        // 1) Filename matches — fd if available, else a FileManager walk.
        var names = fdNames(root: root, needle: needle, cap: cap)
            ?? fmNames(root: root, needle: needle, maxDepth: maxDepth, cap: cap)
        // Fuzzy-rank with fzf when present (purely reorders the candidate set).
        names = fzfRank(names, query: needle) ?? names
        for url in names where results.count < cap { add(url, content: false) }

        // 2) Content matches — ripgrep, appended after filename hits.
        if results.count < cap, !Task.isCancelled {
            for url in rgContent(root: root, needle: needle, cap: cap - results.count) {
                add(url, content: true)
            }
        }
        return results
    }

    // MARK: - fd (filenames)

    private static func fdNames(root: URL, needle: String, cap: Int) -> [URL]? {
        guard let fd = ExternalTools.path("fd") else { return nil }
        let lines = ExternalTools.run(fd, [
            "--color=never", "--absolute-path", "--no-ignore",
            "--fixed-strings", "--type", "f", "--type", "d",
            "--max-results", "\(cap)", needle, root.path
        ], maxLines: cap)
        return lines.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - FileManager fallback

    private static func fmNames(root: URL, needle: String,
                                maxDepth: Int, cap: Int) -> [URL] {
        let fm = FileManager.default
        guard let en = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }
        var urls: [URL] = []
        for case let url as URL in en {
            if en.level > maxDepth { en.skipDescendants(); continue }
            if Task.isCancelled || urls.count >= cap { break }
            if url.lastPathComponent.localizedCaseInsensitiveContains(needle) {
                urls.append(url)
            }
        }
        return urls
    }

    // MARK: - fzf (fuzzy ranking)

    private static func fzfRank(_ urls: [URL], query: String) -> [URL]? {
        guard urls.count > 1, let fzf = ExternalTools.path("fzf") else { return nil }
        let byPath = Dictionary(urls.map { ($0.path, $0) }, uniquingKeysWith: { a, _ in a })
        let input = urls.map(\.path).joined(separator: "\n")
        let ranked = ExternalTools.run(fzf, ["--filter", query],
                                       stdin: input, maxLines: urls.count)
            .compactMap { byPath[$0] }
        return ranked.isEmpty ? nil : ranked
    }

    // MARK: - ripgrep (content)

    private static func rgContent(root: URL, needle: String, cap: Int) -> [URL] {
        guard let rg = ExternalTools.path("rg") else { return [] }
        let lines = ExternalTools.run(rg, [
            "--color=never", "--files-with-matches", "--smart-case",
            "--max-count", "1", "--no-messages", "--", needle, root.path
        ], maxLines: cap)
        return lines.map { URL(fileURLWithPath: $0) }
    }
}
