import SwiftUI
import AppKit

/// Multi-column list view backed by a **native AppKit `NSTableView`** (not SwiftUI
/// `Table`). NSTableView is fully view-recycling: it only realises the handful of
/// rows on screen regardless of the row count, so a 27k-entry folder renders
/// instantly — SwiftUI `Table` diffs every row identity on the main thread and
/// chokes at that scale.
struct FileListView: NSViewRepresentable {
    @Bindable var model: BrowserModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator
        let table = FileTableView()
        table.coordinator = coord
        table.allowsMultipleSelection = true
        table.usesAlternatingRowBackgroundColors = false
        table.style = .inset
        table.rowSizeStyle = .custom
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
        context.coordinator.sync()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var model: BrowserModel
        weak var table: NSTableView?
        private let syncState = ListSyncState()
        private var lastScale = 1.0
        private var lastEditingID: FileItem.ID?

        init(model: BrowserModel) { self.model = model }

        var items: [FileItem] { model.items }

        func applyRowHeight() {
            table?.rowHeight = max(20, 18 * model.textScale + 6)
        }

        /// Row identity of the listing we last applied — input for the diff below.
        private var lastIDs: [FileItem.ID] = []

        /// Reconcile the table with the model (called from updateNSView).
        func sync() {
            guard let table else { return }
            model.contentScrollView = table.enclosingScrollView
            if lastScale != model.textScale {
                lastScale = model.textScale
                applyRowHeight()
                syncState.invalidateItems()   // force a reload so fonts repaint
                lastIDs = []
            }
            if syncState.itemsChanged(version: model.itemsVersion) {
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
                table.reloadData()
                return
            case .incremental:
                break
            }
            let diff = newIDs.difference(from: lastIDs)
            table.beginUpdates()
            var removals = IndexSet()
            var insertions = IndexSet()
            for change in diff {
                switch change {
                case .remove(let offset, _, _): removals.insert(offset)
                case .insert(let offset, _, _): insertions.insert(offset)
                }
            }
            table.removeRows(at: removals, withAnimation: .effectFade)
            table.insertRows(at: insertions, withAnimation: .effectFade)
            table.endUpdates()
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
            let want = IndexSet(model.selection.compactMap { model.index(of: $0) })
            if want != table.selectedRowIndexes {
                syncState.applying {
                    table.selectRowIndexes(want, byExtendingSelection: false)
                }
                if scroll, let first = want.first { table.scrollRowToVisible(first) }
            }
        }

        private func applyEditing() {
            guard let table else { return }
            guard model.editingItemID != lastEditingID else { return }
            lastEditingID = model.editingItemID
            guard let id = model.editingItemID,
                  let row = items.firstIndex(where: { $0.id == id }) else { return }
            table.scrollRowToVisible(row)
            DispatchQueue.main.async { [weak self, weak table] in
                guard let self, let table else { return }
                // Re-resolve the row: a reload may have landed between scheduling
                // and now, so the captured index could point at a different (or
                // nonexistent) item — editColumn on a stale row edits the wrong
                // file or crashes out of range.
                guard let row = self.items.firstIndex(where: { $0.id == id }),
                      row < table.numberOfRows else { return }
                // The table must be first responder for editColumn to open the
                // field editor — after a previous rename committed, focus may have
                // moved off it, which is why a second Enter did nothing.
                table.window?.makeFirstResponder(table)
                table.editColumn(0, row: row, with: nil, select: true)
            }
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { items.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            guard row < items.count, let col = tableColumn?.identifier.rawValue else { return nil }
            let item = items[row]
            let size = 13 * model.textScale
            let subSize = 12 * model.textScale

            if col == "name" {
                let cell = (tableView.makeView(withIdentifier: .nameCell, owner: self) as? NameCell)
                    ?? NameCell()
                cell.identifier = .nameCell
                cell.textField?.delegate = self
                cell.configure(item: item, fontSize: size)
                return cell
            }
            let cell = (tableView.makeView(withIdentifier: .textCell, owner: self) as? PlainCell)
                ?? PlainCell()
            cell.identifier = .textCell
            let text: String
            switch col {
            case "date": text = Format.when(item.modified)
            case "size": text = item.isBrowsableContainer ? "—" : Format.bytes(item.size)
            case "kind": text = Format.kind(item)
            default:     text = ""
            }
            cell.set(text, fontSize: subSize, trailing: col == "size")
            return cell
        }

        // MARK: Selection

        func tableViewSelectionDidChange(_ notification: Notification) {
            guard !syncState.isSyncing, let table else { return }
            let ids = table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].id : nil }
            let newSel = Set(ids)
            syncState.recordApplied(newSel)
            if newSel != model.selection { model.selection = newSel }
        }

        @objc func doubleClicked() {
            guard let table, table.clickedRow >= 0, table.clickedRow < items.count else { return }
            model.open(items[table.clickedRow])
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
            view.stripe = row % 2 == 1
            return view
        }

        /// Row indices shift on incremental diffs, so re-derive every visible
        /// row's zebra stripe after structural changes.
        private func restripe(_ table: NSTableView) {
            table.enumerateAvailableRowViews { rowView, row in
                (rowView as? RoundedRowView)?.stripe = row % 2 == 1
            }
        }

        // MARK: Drag

        func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
            row < items.count ? items[row].url as NSURL : nil
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
            guard row >= 0, row < items.count else { return nil }
            return FileItemMenu.build(for: items[row], model: model)
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

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        guard stripe else { return }
        NSColor.textColor.withAlphaComponent(0.04).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 6, dy: 1), xRadius: 7, yRadius: 7).fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 6, dy: 1)
        let color = isEmphasized
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
}

/// Name column cell: icon + editable label.
private final class NameCell: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let tagDot = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none
        tagDot.translatesAutoresizingMaskIntoConstraints = false
        tagDot.wantsLayer = true
        tagDot.layer?.cornerRadius = 3.5
        addSubview(icon); addSubview(label); addSubview(tagDot)
        textField = label
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            // A tag swatch sits after the name; the name truncates before it.
            label.trailingAnchor.constraint(lessThanOrEqualTo: tagDot.leadingAnchor, constant: -6),
            tagDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            tagDot.centerYAnchor.constraint(equalTo: centerYAnchor),
            tagDot.widthAnchor.constraint(equalToConstant: 7),
            tagDot.heightAnchor.constraint(equalToConstant: 7),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(item: FileItem, fontSize: CGFloat) {
        icon.image = IconProvider.shared.icon(for: item)
        label.stringValue = item.name
        label.font = .systemFont(ofSize: fontSize)
        label.isEditable = true   // rename starts via editColumn; clicks won't edit
        let tagColor = FileTags.primaryColor(of: item.url)
        tagDot.isHidden = tagColor == nil
        tagDot.layer?.backgroundColor = tagColor?.cgColor
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
