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

        addColumn(table, "name", "Name", min: 220, width: 380)
        addColumn(table, "date", "Date Modified", min: 120, width: 180)
        addColumn(table, "size", "Size", min: 70, width: 90)
        addColumn(table, "kind", "Kind", min: 90, width: 160)

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
        private var lastVersion = -1
        private var lastScale = 1.0
        private var lastEditingID: FileItem.ID?
        private var syncingSelection = false

        init(model: BrowserModel) { self.model = model }

        var items: [FileItem] { model.items }

        func applyRowHeight() {
            table?.rowHeight = max(20, 18 * model.textScale + 6)
        }

        /// Reconcile the table with the model (called from updateNSView).
        func sync() {
            guard let table else { return }
            if lastScale != model.textScale {
                lastScale = model.textScale
                applyRowHeight()
                lastVersion = -1   // force a reload so fonts repaint
            }
            if lastVersion != model.itemsVersion {
                lastVersion = model.itemsVersion
                table.reloadData()
                applyModelSelection(scroll: false)
            } else {
                applyModelSelection(scroll: true)
            }
            applyEditing()
        }

        private func applyModelSelection(scroll: Bool) {
            guard let table else { return }
            let want = IndexSet(items.enumerated()
                .filter { model.selection.contains($0.element.id) }
                .map(\.offset))
            if want != table.selectedRowIndexes {
                syncingSelection = true
                table.selectRowIndexes(want, byExtendingSelection: false)
                syncingSelection = false
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
            DispatchQueue.main.async { [weak table] in
                guard let table else { return }
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
            guard !syncingSelection, let table else { return }
            let ids = table.selectedRowIndexes.compactMap { $0 < items.count ? items[$0].id : nil }
            let newSel = Set(ids)
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
            let item = items[row]
            if !model.selection.contains(item.id) { model.selection = [item.id] }
            let menu = NSMenu()
            func add(_ title: String, _ action: @escaping () -> Void) {
                let mi = NSMenuItem(title: title, action: #selector(MenuTarget.fire), keyEquivalent: "")
                let t = MenuTarget(action); mi.target = t; mi.representedObject = t
                menu.addItem(mi)
            }
            add("Open") { self.model.open(item) }
            if item.isBrowsableContainer {
                add("Open Terminal Here") { FileOperations.openInTerminal(item.url) }
            }
            menu.addItem(.separator())
            if model.selection.count > 1 {
                add("Rename \(model.selection.count) Items…") { self.model.batchRename() }
            } else {
                add("Rename") { self.model.beginRename() }
            }
            add("Duplicate") { self.model.duplicateSelection() }
            menu.addItem(.separator())
            add("Copy") { self.model.copySelectionToPasteboard() }
            add("Copy Path") { self.model.copyPathToPasteboard() }
            add("Paste") { self.model.pasteFromPasteboard() }
            add("Reveal in Finder") { self.model.revealSelection() }
            menu.addItem(.separator())
            add("Move to Trash") { self.model.trashSelection() }
            return menu
        }
    }
}

/// Retains a closure for an NSMenuItem target.
private final class MenuTarget: NSObject {
    let action: () -> Void
    init(_ action: @escaping () -> Void) { self.action = action }
    @objc func fire() { action() }
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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.focusRingType = .none
        addSubview(icon); addSubview(label)
        textField = label
        imageView = icon
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            icon.heightAnchor.constraint(equalToConstant: 16),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(item: FileItem, fontSize: CGFloat) {
        icon.image = IconProvider.shared.icon(for: item)
        label.stringValue = item.name
        label.font = .systemFont(ofSize: fontSize)
        label.isEditable = true   // rename starts via editColumn; clicks won't edit
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
