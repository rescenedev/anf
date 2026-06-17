import SwiftUI
import AppKit

/// Multi-column list view backed by a **native AppKit `NSTableView`** (not SwiftUI
/// `Table`). NSTableView is fully view-recycling: it only realises the handful of
/// rows on screen regardless of the row count, so a 27k-entry folder renders
/// instantly — SwiftUI `Table` diffs every row identity on the main thread and
/// chokes at that scale.
struct FileListView: NSViewRepresentable {
    @Bindable var model: BrowserModel
    /// Whether this pane is the focused one (always true in a single-pane layout).
    /// Drives whether the selection draws emphasized or muted (issue #59).
    var paneActive: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator
        let table = FileTableView()
        table.coordinator = coord
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.style = .inset
        table.rowSizeStyle = .custom
        table.floatsGroupRows = false   // Arrange-by headers scroll with their group
        table.intercellSpacing = NSSize(width: 8, height: 2)
        table.dataSource = coord
        table.delegate = coord
        table.target = coord
        table.doubleAction = #selector(Coordinator.doubleClicked)
        table.allowsColumnReordering = false
        table.registerForDraggedTypes([.fileURL])
        table.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        table.setDraggingSourceOperationMask([.copy], forLocal: false)

        addColumn(table, "name", L("Name", "이름"), min: 220, width: 380)
        addColumn(table, "date", L("Date Modified", "수정일"), min: 120, width: 180)
        addColumn(table, "size", L("Size", "크기"), min: 70, width: 90)
        addColumn(table, "kind", L("Kind", "종류"), min: 90, width: 160)

        table.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        // Persist column widths/order across view-mode switches and relaunches.
        // Without this the table is rebuilt with the default widths every time the
        // representable is re-made (e.g. toggling icon ↔ list), so a user's column
        // resize appeared to "reset". Set after the columns exist so AppKit can
        // match saved widths to their identifiers. (issue #12)
        table.autosaveName = "anf.fileList.columns"
        table.autosaveTableColumns = true
        coord.table = table

        table.backgroundColor = .clear

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        coord.applyRowHeight()
        return scroll
    }

    private func addColumn(_ table: NSTableView, _ id: String, _ title: String,
                           min: CGFloat, width: CGFloat) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        col.title = title
        col.minWidth = min
        col.width = width
        col.sortDescriptorPrototype = NSSortDescriptor(key: id, ascending: true)
        table.addTableColumn(col)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.setPaneActive(paneActive)
        context.coordinator.sync()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var model: BrowserModel
        weak var table: NSTableView?
        /// Mirrors FileListView.paneActive; pushed to every visible row so the
        /// unfocused pane's selection draws muted (issue #59).
        private(set) var paneActive = true
        private let syncState = ListSyncState()
        private var lastScale = 1.0
        private var lastEditingID: FileItem.ID?

        init(model: BrowserModel) { self.model = model }

        var items: [FileItem] { model.items }

        // MARK: Row model (grouping)
        //
        // When Arrange-by is active the table interleaves group-header rows with
        // file rows. `items` stays the flat file list (keyboard nav is unchanged);
        // these maps translate between table rows and item indices.
        enum RowKind { case header(String); case item(Int) }
        private var rowKinds: [RowKind] = []
        private var rowForItem: [Int] = []   // itemIndex → table row

        /// Rebuild the table's row model from `model.items` + `model.groupRanges`.
        private func rebuildRows() {
            let groups = model.groupRanges
            let count = items.count
            if groups.isEmpty {
                rowKinds = (0..<count).map { .item($0) }
                rowForItem = Array(0..<count)        // identity when flat
                return
            }
            var rows: [RowKind] = []; rows.reserveCapacity(count + groups.count)
            var map = [Int](repeating: 0, count: count)
            for g in groups {
                rows.append(.header(g.title))
                for i in g.range where i < count {
                    map[i] = rows.count
                    rows.append(.item(i))
                }
            }
            rowKinds = rows
            rowForItem = map
        }

        /// The file at a table row, or nil for a group header.
        private func item(atRow row: Int) -> FileItem? {
            guard row >= 0, row < rowKinds.count, case .item(let i) = rowKinds[row], i < items.count
            else { return nil }
            return items[i]
        }

        private func isHeaderRow(_ row: Int) -> Bool {
            guard row >= 0, row < rowKinds.count else { return false }
            if case .header = rowKinds[row] { return true }
            return false
        }

        /// Table row for a model item index (accounts for preceding headers).
        private func row(forItemIndex i: Int) -> Int? {
            guard i >= 0, i < rowForItem.count else { return nil }
            return rowForItem[i]
        }

        func applyRowHeight() {
            table?.rowHeight = max(20, 18 * model.textScale + 6)
        }

        /// Row identity of the listing we last applied — input for the diff below.
        private var lastIDs: [FileItem.ID] = []

        /// Reconcile the table with the model (called from updateNSView).
        func sync() {
            guard let table else { return }
            model.contentScrollView = table.enclosingScrollView
            // Tab switch reuses this coordinator with the next tab's model; its
            // version counter and row-id cache belong to the previous tab, so
            // force a clean reload (else a colliding itemsVersion shows the old
            // tab's listing under the newly-selected tab).
            if syncState.modelChanged(model.id) { lastIDs = [] }
            if lastScale != model.textScale {
                lastScale = model.textScale
                applyRowHeight()
                syncState.invalidateItems()   // force a reload so fonts repaint
                lastIDs = []
            }
            rebuildRows()
            if model.grouped {
                // Grouped: the table has header rows, so the item-id Myers diff
                // doesn't map to table rows — reload wholesale on any change.
                if syncState.itemsChanged(version: model.itemsVersion) {
                    syncState.applying { table.reloadData() }
                    applyModelSelection(scroll: false, force: true)
                } else {
                    applyModelSelection(scroll: true)
                }
                lastIDs = []   // force a clean reload if grouping turns back off
            } else if syncState.itemsChanged(version: model.itemsVersion) {
                applyListDiff(to: table)
                // Items changed → row indices may have shifted; re-map even if the
                // selection set itself is identical.
                applyModelSelection(scroll: false, force: true)
            } else {
                applyModelSelection(scroll: true)
            }
            applyEditing()
        }

        /// Update rows incrementally instead of `reloadData()`: live changes (a
        /// file created/renamed/deleted under FSEvents, an iCloud item landing)
        /// animate just the affected rows and keep scroll position — no full-table
        /// flash. Navigation (mostly-different listing) still reloads wholesale,
        /// since a 26k-vs-26k Myers diff with a huge edit distance costs more than
        /// it saves.
        private func applyListDiff(to table: NSTableView) {
            let newIDs = items.map(\.id)
            defer { lastIDs = newIDs }

            switch ListDiff.strategy(old: lastIDs, new: newIDs) {
            case .visibleRefresh:
                // Same rows in the same order → only the content of some rows
                // changed (sizes/dates from a reload). Refresh what's on screen.
                reloadVisibleRows(table)
                return
            case .reload:
                // `applying`: removing rows makes NSTableView fire
                // tableViewSelectionDidChange, which would clobber the model's
                // selection (e.g. the folder we just re-selected on a tree
                // collapse) back to the table's empty set.
                syncState.applying { table.reloadData() }
                return
            case .incremental:
                break
            }
            let diff = newIDs.difference(from: lastIDs)
            var removals = IndexSet()
            var insertions = IndexSet()
            for change in diff {
                switch change {
                case .remove(let offset, _, _): removals.insert(offset)
                case .insert(let offset, _, _): insertions.insert(offset)
                }
            }
            syncState.applying {
                table.beginUpdates()
                table.removeRows(at: removals, withAnimation: .effectFade)
                table.insertRows(at: insertions, withAnimation: .effectFade)
                table.endUpdates()
            }
            // Rows that stayed put may still carry fresh metadata — and their
            // indices (so their zebra stripes) may have shifted.
            reloadVisibleRows(table)
            restripe(table)
        }

        private func reloadVisibleRows(_ table: NSTableView) {
            let visible = table.rows(in: table.visibleRect)
            guard visible.length > 0 else { return }
            table.reloadData(
                forRowIndexes: IndexSet(integersIn: visible.location ..< visible.location + visible.length),
                columnIndexes: IndexSet(integersIn: 0 ..< table.numberOfColumns))
        }


        private func applyModelSelection(scroll: Bool, force: Bool = false) {
            guard let table else { return }
            guard syncState.selectionChanged(model.selection, force: force) else { return }
            // Map item indices to table rows (headers shift them when grouped).
            let want = IndexSet(model.selection
                .compactMap { model.index(of: $0) }
                .compactMap { row(forItemIndex: $0) })
            if want != table.selectedRowIndexes {
                syncState.applying {
                    table.selectRowIndexes(want, byExtendingSelection: false)
                }
                // Follow the moving cursor (the growing edge of a shift-select),
                // not the topmost row — otherwise shift+↓ / shift+PgDn never
                // scroll because the top stays put. Fall back to the topmost.
                let cursorRow = model.selectionCursorIndex.flatMap { row(forItemIndex: $0) }
                if scroll, let target = cursorRow ?? want.first {
                    table.scrollRowToVisible(target)
                }
            }
        }

        private func applyEditing() {
            guard let table else { return }
            guard model.editingItemID != lastEditingID else { return }
            lastEditingID = model.editingItemID
            guard let id = model.editingItemID,
                  let idx = items.firstIndex(where: { $0.id == id }),
                  let row = row(forItemIndex: idx) else { return }
            table.scrollRowToVisible(row)
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table else { return }
                // Re-resolve the row: a reload may have landed between scheduling
                // and now, so the captured index could point at a different (or
                // nonexistent) item — editColumn on a stale row edits the wrong
                // file or crashes out of range.
                guard let idx = self.items.firstIndex(where: { $0.id == id }),
                      let row = self.row(forItemIndex: idx),
                      row < table.numberOfRows else { return }
                // The table must be first responder for editColumn to open the
                // field editor — after a previous rename committed, focus may have
                // moved off it, which is why a second Enter did nothing.
                table.window?.makeFirstResponder(table)
                table.editColumn(0, row: row, with: nil, select: true)
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { rowKinds.count }

        // MARK: Grouping rows

        func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool { isHeaderRow(row) }

        func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { !isHeaderRow(row) }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
            isHeaderRow(row) ? max(22, 17 * model.textScale + 8) : max(20, 18 * model.textScale + 6)
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            // Group header: a single full-width label (group rows ignore columns,
            // but NSTableView still asks the first column once).
            if isHeaderRow(row), case .header(let title) = rowKinds[row] {
                guard tableColumn == nil || tableColumn?.identifier.rawValue == "name" else { return nil }
                let cell = (tableView.makeView(withIdentifier: .groupCell, owner: self) as? GroupHeaderCell)
                    ?? GroupHeaderCell()
                cell.identifier = .groupCell
                cell.set(title, fontSize: 11 * model.textScale)
                return cell
            }
            guard let item = item(atRow: row), let col = tableColumn?.identifier.rawValue else { return nil }
            let size = 13 * model.textScale
            let subSize = 12 * model.textScale

            if col == "name" {
                let cell = (tableView.makeView(withIdentifier: .nameCell, owner: self) as? NameCell)
                    ?? NameCell()
                cell.identifier = .nameCell
                cell.textField?.delegate = self
                let model = self.model
                cell.configure(item: item, fontSize: size,
                               depth: model.depth(of: item),
                               expandable: model.isExpandable(item),
                               expanded: model.isExpanded(item),
                               onToggle: { model.toggleExpand(item) })
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: .textCell, owner: self) as? PlainCell)
                ?? PlainCell()
            cell.identifier = .textCell
            let text: String
            if item.isParentRef {
                text = ""   // the ".." row carries no date/size/kind
            } else {
                switch col {
                case "date": text = Format.when(item.modified)
                case "size": text = item.isBrowsableContainer ? "—" : Format.bytes(item.size)
                case "kind": text = Format.kind(item)
                default:     text = ""
                }
            }
            cell.set(text, fontSize: subSize, trailing: col == "size")
            return cell
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncState.isSyncing, let table else { return }
            let ids = table.selectedRowIndexes.compactMap { item(atRow: $0)?.id }
            let newSel = Set(ids)
            syncState.recordApplied(newSel)
            if newSel != model.selection { model.selection = newSel }
        }

        @objc func doubleClicked() {
            guard let table, let it = item(atRow: table.clickedRow) else { return }
            model.open(it)
        }

        // MARK: Sorting

        func tableView(_ tableView: NSTableView, sortDescriptorsDidChange old: [NSSortDescriptor]) {
            guard let d = tableView.sortDescriptors.first, let key = d.key else { return }
            let mapped: SortKey
            switch key {
            case "date": mapped = .dateModified
            case "size": mapped = .size
            case "kind": mapped = .kind
            default:     mapped = .name
            }
            model.sort = SortOrder(key: mapped, ascending: d.ascending)
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let view = RoundedRowView()
            // No zebra stripes when grouped — the headers already segment the list.
            view.stripe = !isHeaderRow(row) && !model.grouped && row % 2 == 1
            view.paneActive = paneActive
            return view
        }

        /// Update the focused-pane flag and repaint visible selections so the
        /// unfocused pane dims as soon as focus moves (issue #59).
        func setPaneActive(_ active: Bool) {
            guard active != paneActive else { return }
            paneActive = active
            table?.enumerateAvailableRowViews { rowView, _ in
                (rowView as? RoundedRowView)?.paneActive = active
            }
        }

        /// Row indices shift on incremental diffs, so re-derive every visible
        /// row's zebra stripe after structural changes.
        private func restripe(_ table: NSTableView) {
            table.enumerateAvailableRowViews { rowView, row in
                (rowView as? RoundedRowView)?.stripe = row % 2 == 1
            }
        }

        // MARK: Drag & drop

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            // The ".." row is not draggable — it has no real file behind it.
            guard let it = item(atRow: row), !it.isParentRef else { return nil }
            return it.url as NSURL
        }

        // Without these two, registering for dragged types makes the table SWALLOW
        // drops (it's a registered destination that rejects everything), so the
        // SwiftUI `.dropDestination` behind it never fires — pane-to-pane file move
        // in list mode silently fails. Drop onto a folder row → into that folder;
        // anywhere else → into the current folder.
        func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                       proposedRow row: Int,
                       proposedDropOperation op: NSTableView.DropOperation) -> NSDragOperation {
            guard info.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: nil) else { return [] }
            if !(op == .on && isDropFolder(item(atRow: row))) {
                tableView.setDropRow(-1, dropOperation: .above)   // whole-table drop
            }
            return copyRequested(info) ? .copy : .move
        }

        func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                       row: Int, dropOperation op: NSTableView.DropOperation) -> Bool {
            guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                                 options: nil) as? [URL],
                  !urls.isEmpty else { return false }
            let dropFolder = (op == .on && isDropFolder(item(atRow: row))) ? item(atRow: row) : nil
            let into: URL = dropFolder?.url ?? model.currentURL
            // Never drop a folder into itself or its own subtree.
            guard !urls.contains(where: { into.path == $0.path || into.path.hasPrefix($0.path + "/") })
            else { return false }
            model.acceptDrop(urls, into: into, copy: copyRequested(info))
            return true
        }

        /// A row that accepts a drop INTO it: a real browsable folder, never the
        /// synthetic ".." row (which has no real file behind it).
        private func isDropFolder(_ item: FileItem?) -> Bool {
            guard let item else { return false }
            return item.isBrowsableContainer && !item.isParentRef
        }

        /// Option held narrows the source mask to copy-only (and external drags
        /// arrive copy-only); otherwise it's a move.
        private func copyRequested(_ info: NSDraggingInfo) -> Bool {
            info.draggingSourceOperationMask == .copy
        }

        // MARK: Inline rename commit

        func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool { true }

        func controlTextDidEndEditing(_ obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let id = lastEditingID,
                  let item = items.first(where: { $0.id == id }) else { return }
            let newName = field.stringValue
            lastEditingID = nil
            model.commitRename(item, to: newName)
            // Return focus to the table so the next Enter starts a new rename
            // (otherwise the lingering field editor swallows it).
            if let table { table.window?.makeFirstResponder(table) }
        }

        // MARK: Context menu

        func menu(forRow row: Int) -> NSMenu? {
            // Empty space → the folder's background menu (New Folder, Vault, …),
            // matching the icon grid. A clicked row → that item's menu.
            // Empty space and the synthetic ".." row → background menu (no
            // file-specific actions that could target the parent).
            guard let it = item(atRow: row), !it.isParentRef else { return FileItemMenu.background(model: model) }
            return FileItemMenu.build(for: it, model: model)
        }
    }
}

/// Rounded, inset selection highlight drawn by hand: the system `.inset` style
/// renders it correctly in a lone pane but falls back to square full-bleed rows
/// when the pane is narrow (horizontal scrolling) — custom drawing is identical
/// everywhere.
/// Decides how the table reconciles a listing change. Pulled out of the
/// coordinator so the decision is unit-testable — the Myers diff
/// (`difference(from:)`) is O(N·D), and a sort flip produces the worst case
/// (same 26k IDs, edit distance ≈ 2N → seconds of main-thread beachball), so
/// it must NEVER be fed a reorder.
enum ListDiff {
    enum Strategy: Equatable { case visibleRefresh, reload, incremental }

    static func strategy(old: [FileItem.ID], new: [FileItem.ID]) -> Strategy {
        if new == old { return .visibleRefresh }
        guard !old.isEmpty else { return .reload }
        let common = Set(new).intersection(Set(old)).count
        // Mostly-different listing (navigation, filter) → nothing to animate.
        guard common * 2 > max(new.count, old.count) else { return .reload }
        // Same IDs in a different order (sort change) → the diff would be the
        // pathological case, and an animated 26k-row shuffle is useless anyway.
        if common == new.count, common == old.count { return .reload }
        // Small membership change (file created/renamed/deleted) → animate.
        return .incremental
    }
}

final class RoundedRowView: NSTableRowView {
    /// Finder-style zebra striping: every other row gets a faint wash so the eye
    /// can follow a row across the date/size columns. Translucent (textColor at
    /// 4%) so the under-window blur keeps showing through in both appearances.
    var stripe = false {
        didSet { if stripe != oldValue { needsDisplay = true } }
    }

    /// False when this row's pane isn't the focused one in a split layout, so its
    /// selection draws muted instead of accent-blue (issue #59: both panes looked
    /// equally selected). Single-pane and the active pane stay emphasized.
    var paneActive = true {
        didSet { if paneActive != oldValue && isSelected { needsDisplay = true } }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard stripe else { return }
        NSColor.textColor.withAlphaComponent(0.04).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        // Finder-style: accent blue whenever the window is key (so clicking a
        // disclosure triangle or the sidebar doesn't drop it to gray); muted when
        // the whole window is inactive, OR when this is the unfocused pane of a
        // split (issue #59 — only the focused pane shows the emphasized selection).
        let key = (window?.isKeyWindow ?? false) && paneActive
        let color = key
            ? NSColor.selectedContentBackgroundColor
            : NSColor.unemphasizedSelectedContentBackgroundColor
        color.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
}

/// NSTableView that builds a row-aware context menu and lets the global keyboard
/// monitor handle navigation keys.
final class FileTableView: NSTableView {
    weak var coordinator: FileListView.Coordinator?

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        return coordinator?.menu(forRow: row)
    }
}

private extension NSUserInterfaceItemIdentifier {
    static let nameCell = NSUserInterfaceItemIdentifier("anf.name")
    static let textCell = NSUserInterfaceItemIdentifier("anf.text")
    static let groupCell = NSUserInterfaceItemIdentifier("anf.group")
}

/// Group header row (Arrange-by): a bottom-aligned, semibold secondary label
/// spanning the row. Rendered for rows the table treats as group rows.
final class GroupHeaderCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBordered = false; label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        label.textColor = .secondaryLabelColor
        addSubview(label); textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ text: String, fontSize: CGFloat) {
        label.stringValue = text
        label.font = .systemFont(ofSize: max(10, fontSize), weight: .semibold)
    }
}

/// Name column cell: [disclosure ▸] icon + editable label, indented by tree depth.
private final class NameCell: NSTableCellView {
    private let disclosure = NSButton()
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let tagText = NSTextField(labelWithString: "")
    private let tagDot = NSView()
    private var indent: NSLayoutConstraint!
    private static let step: CGFloat = 14     // indent per depth level / triangle slot
    private var onToggle: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        for v in [icon, label, tagText, tagDot, disclosure] { v.translatesAutoresizingMaskIntoConstraints = false }
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false; label.isBordered = false
        label.drawsBackground = false; label.focusRingType = .none
        tagDot.wantsLayer = true; tagDot.layer?.cornerRadius = 3.5
        tagText.lineBreakMode = .byTruncatingTail
        tagText.isBordered = false; tagText.drawsBackground = false
        tagText.textColor = .tertiaryLabelColor
        tagText.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        disclosure.isBordered = false
        disclosure.bezelStyle = .regularSquare
        disclosure.imagePosition = .imageOnly
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.refusesFirstResponder = true   // don't steal focus → selection stays blue
        disclosure.target = self
        disclosure.action = #selector(toggle)
        disclosure.symbolConfiguration = .init(pointSize: 9, weight: .semibold)

        addSubview(disclosure); addSubview(icon); addSubview(label); addSubview(tagText); addSubview(tagDot)
        textField = label
        imageView = icon
        indent = disclosure.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2)
        NSLayoutConstraint.activate([
            indent,
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: Self.step),
            icon.leadingAnchor.constraint(equalTo: disclosure.trailingAnchor, constant: 1),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: tagText.leadingAnchor, constant: -8),
            tagText.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagText.trailingAnchor.constraint(lessThanOrEqualTo: tagDot.leadingAnchor, constant: -6),
            tagDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tagDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagDot.widthAnchor.constraint(equalToConstant: 7),
            tagDot.heightAnchor.constraint(equalToConstant: 7),
        ])
        label.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc private func toggle() { onToggle?() }

    func configure(item: FileItem, fontSize: CGFloat,
                   depth: Int, expandable: Bool, expanded: Bool, onToggle: (() -> Void)?) {
        // The synthetic ".." row: an up-arrow glyph, no rename/disclosure/tags.
        if item.isParentRef {
            icon.image = NSImage(systemSymbolName: "arrowshape.turn.up.left.fill",
                                 accessibilityDescription: "Parent folder")
            icon.contentTintColor = .secondaryLabelColor
            label.stringValue = ".."
            label.font = .systemFont(ofSize: fontSize)
            label.isEditable = false
            self.onToggle = nil
            indent.constant = 2
            disclosure.isHidden = true
            tagDot.isHidden = true
            tagText.isHidden = true
            return
        }
        icon.contentTintColor = nil
        icon.image = IconProvider.shared.icon(for: item)
        label.stringValue = item.name
        label.font = .systemFont(ofSize: fontSize)
        label.isEditable = true   // rename starts via editColumn; clicks won't edit
        self.onToggle = onToggle
        indent.constant = 2 + CGFloat(depth) * Self.step
        disclosure.isHidden = !expandable
        disclosure.image = NSImage(systemSymbolName: expanded ? "chevron.down" : "chevron.right",
                                   accessibilityDescription: nil)
        let tags = FileTags.display(of: item.url)
        tagDot.isHidden = tags.color == nil
        tagDot.layer?.backgroundColor = tags.color?.cgColor
        tagText.isHidden = tags.named.isEmpty
        tagText.stringValue = tags.named.joined(separator: "  ")
        tagText.font = .systemFont(ofSize: max(9, fontSize - 2))
    }
}

/// Plain text cell for the secondary columns.
private final class PlainCell: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.isBordered = false
        label.drawsBackground = false
        label.textColor = .secondaryLabelColor
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func set(_ text: String, fontSize: CGFloat, trailing: Bool) {
        label.stringValue = text
        label.font = .systemFont(ofSize: fontSize)
        label.alignment = trailing ? .right : .left
    }
}
