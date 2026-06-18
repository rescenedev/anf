import AppKit
import SwiftUI

/// Icon grid backed by a native `NSCollectionView` (not SwiftUI's LazyVGrid):
/// real view recycling for huge folders, rubber-band drag selection, the same
/// `NSMenu` as the list view, and native drag & drop.
struct IconGridView: NSViewRepresentable {
    @Bindable var model: BrowserModel
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onFocus: onFocus) }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator

        let layout = NSCollectionViewFlowLayout()
        layout.sectionInset = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.itemSize = Coordinator.itemSize(icon: model.iconSize)

        let cv = GridCollectionView()
        cv.coordinator = coord
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = true
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.dataSource = coord
        cv.delegate = coord
        cv.register(IconItem.self, forItemWithIdentifier: IconItem.reuseID)
        cv.register(GridSectionHeader.self,
                    forSupplementaryViewOfKind: NSCollectionView.elementKindSectionHeader,
                    withIdentifier: GridSectionHeader.reuseID)
        cv.setDraggingSourceOperationMask([.copy, .move, .generic], forLocal: true)
        cv.setDraggingSourceOperationMask([.copy], forLocal: false)
        cv.registerForDraggedTypes([.fileURL])
        coord.collection = cv

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false

        // Re-report column count whenever the pane resizes.
        cv.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            coord, selector: #selector(Coordinator.frameChanged),
            name: NSView.frameDidChangeNotification, object: cv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.onFocus = onFocus
        context.coordinator.sync()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegateFlowLayout {
        var model: BrowserModel
        var onFocus: () -> Void
        weak var collection: NSCollectionView?
        private let syncState = ListSyncState()
        private var lastIconSize: Double = 0
        private var lastEditingID: FileItem.ID?

        init(model: BrowserModel, onFocus: @escaping () -> Void) {
            self.model = model
            self.onFocus = onFocus
        }

        deinit {
            // Selector-based observers auto-clear on macOS 11+, but remove explicitly
            // so the frameDidChange registration can never outlive this coordinator
            // (G-003). Safe on any thread.
            NotificationCenter.default.removeObserver(self)
        }

        var items: [FileItem] { model.items }

        func focusPaneFromMouse() {
            onFocus()
        }

        static func itemSize(icon: Double) -> NSSize {
            NSSize(width: icon + 28, height: icon + 46)
        }

        // MARK: Grouping (section ↔ flat item-index mapping)
        //
        // When Arrange-by is active each group is a collection-view section with a
        // header; `items` stays the flat (grouped-order) list, so these convert
        // between an IndexPath and the flat index keyboard nav/selection use.
        private var grouped: Bool { model.grouped }

        private func flatIndex(_ ip: IndexPath) -> Int? {
            if !grouped { return ip.item < items.count ? ip.item : nil }
            let groups = model.groupRanges
            guard ip.section < groups.count else { return nil }
            let base = groups[ip.section].range.lowerBound + ip.item
            return base < groups[ip.section].range.upperBound && base < items.count ? base : nil
        }

        private func itemAt(_ ip: IndexPath) -> FileItem? { flatIndex(ip).map { items[$0] } }

        private func indexPath(forFlat i: Int) -> IndexPath? {
            guard i >= 0, i < items.count else { return nil }
            if !grouped { return IndexPath(item: i, section: 0) }
            for (s, g) in model.groupRanges.enumerated() where g.range.contains(i) {
                return IndexPath(item: i - g.range.lowerBound, section: s)
            }
            return nil
        }

        func sync() {
            guard let cv = collection else { return }
            model.contentScrollView = cv.enclosingScrollView
            // Tab switch reuses this coordinator with the next tab's model — force
            // a reload so a colliding per-model itemsVersion can't leave the old
            // tab's grid on screen (mirrors FileListView).
            syncState.modelChanged(model.id)
            if lastIconSize != model.iconSize {
                lastIconSize = model.iconSize
                if let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout {
                    layout.itemSize = Self.itemSize(icon: model.iconSize)
                    layout.invalidateLayout()
                }
                syncState.invalidateItems()   // re-make cells at the new size
            }
            if syncState.itemsChanged(version: model.itemsVersion) {
                cv.reloadData()
                applySelection(cv, force: true, scroll: false)
            } else {
                applySelection(cv, scroll: true)
            }
            reportColumns(cv)
            applyEditing(cv)
        }

        @objc func frameChanged() {
            if let cv = collection { reportColumns(cv) }
        }

        private func reportColumns(_ cv: NSCollectionView) {
            guard let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout else { return }
            let avail = cv.bounds.width - layout.sectionInset.left - layout.sectionInset.right
            let unit = layout.itemSize.width + layout.minimumInteritemSpacing
            model.gridColumns = max(1, Int((avail + layout.minimumInteritemSpacing) / unit))
        }

        private func applySelection(_ cv: NSCollectionView, force: Bool = false, scroll: Bool) {
            guard syncState.selectionChanged(model.selection, force: force) else { return }
            let want = Set(model.selection.compactMap { id in
                model.index(of: id).flatMap { indexPath(forFlat: $0) }
            })
            guard want != cv.selectionIndexPaths else { return }
            syncState.applying {
                cv.deselectItems(at: cv.selectionIndexPaths)
                cv.selectItems(at: want, scrollPosition: [])
            }
            if scroll {
                // Follow the moving cursor (the growing edge of a shift-select),
                // not the topmost item — otherwise shift+↓ / shift+PgDn never
                // scroll because the top stays put. Fall back to the topmost.
                let cursor = model.selectionCursorIndex.flatMap { indexPath(forFlat: $0) }
                let target = cursor ?? want.min(by: { $0.section != $1.section ? $0.section < $1.section : $0.item < $1.item })
                if let target {
                    cv.scrollToItems(at: [target], scrollPosition: .nearestHorizontalEdge)
                }
            }
        }

        private func applyEditing(_ cv: NSCollectionView) {
            guard model.editingItemID != lastEditingID else { return }
            lastEditingID = model.editingItemID
            guard let id = model.editingItemID,
                  let row = items.firstIndex(where: { $0.id == id }),
                  let path = indexPath(forFlat: row) else { return }
            cv.scrollToItems(at: [path], scrollPosition: .nearestHorizontalEdge)
            DispatchQueue.main.async { [weak self, weak cv] in
                guard let self, let cv else { return }
                // Re-resolve by id: a reload may have landed between scheduling and
                // now, so the captured `row`/`path` could be out of range or point at
                // a different file (same guard FileListView.applyEditing uses).
                guard let row = self.items.firstIndex(where: { $0.id == id }),
                      let path = self.indexPath(forFlat: row),
                      let item = cv.item(at: path) as? IconItem else { return }
                let target = self.items[row]
                item.beginRename(
                    onCommit: { [weak self] name in
                        self?.lastEditingID = nil
                        self?.model.commitRename(target, to: name)
                    },
                    onCancel: { [weak self] in
                        self?.lastEditingID = nil
                        self?.model.cancelRename()
                    })
            }
        }

        // MARK: Data source

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            grouped ? model.groupRanges.count : 1
        }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int {
            guard grouped else { return items.count }
            return section < model.groupRanges.count ? model.groupRanges[section].range.count : 0
        }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: IconItem.reuseID,
                                               for: indexPath) as! IconItem
            if let item = itemAt(indexPath) {
                cell.configure(with: item, iconSide: model.iconSize)
                cell.onDoubleClick = { [weak self] in self?.model.open(item) }
            }
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView,
                            viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> NSView {
            let header = collectionView.makeSupplementaryView(
                ofKind: kind, withIdentifier: GridSectionHeader.reuseID, for: indexPath) as! GridSectionHeader
            if grouped, indexPath.section < model.groupRanges.count {
                header.set(model.groupRanges[indexPath.section].title)
            }
            return header
        }

        func collectionView(_ collectionView: NSCollectionView, layout: NSCollectionViewLayout,
                            referenceSizeForHeaderInSection section: Int) -> NSSize {
            grouped ? NSSize(width: 0, height: 28) : .zero
        }

        // MARK: Selection

        func collectionView(_ collectionView: NSCollectionView,
                            didSelectItemsAt indexPaths: Set<IndexPath>) {
            pushSelection(collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            didDeselectItemsAt indexPaths: Set<IndexPath>) {
            pushSelection(collectionView)
        }

        private func pushSelection(_ cv: NSCollectionView) {
            guard !syncState.isSyncing else { return }
            let ids = Set(cv.selectionIndexPaths.compactMap { itemAt($0)?.id })
            syncState.recordApplied(ids)
            if ids != model.selection { model.selection = ids }
        }

        // MARK: Context menu (shared with the list view)

        func menu(at point: NSPoint, in cv: NSCollectionView) -> NSMenu? {
            if let path = cv.indexPathForItem(at: point), let it = itemAt(path) {
                return FileItemMenu.build(for: it, model: model)
            }
            return FileItemMenu.background(model: model)
        }

        // MARK: Drag & drop

        func collectionView(_ collectionView: NSCollectionView,
                            pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
            (itemAt(indexPath)?.url).map { $0 as NSURL }
        }

        func collectionView(_ collectionView: NSCollectionView,
                            validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            // Only "drop ON a folder" is meaningful here; pane-level drops are
            // handled by the SwiftUI dropDestination in ContentArea.
            let path = proposedIndexPath.pointee as IndexPath
            guard dropOperation.pointee == .on, itemAt(path)?.isBrowsableContainer == true else { return [] }
            return .move
        }

        func collectionView(_ collectionView: NSCollectionView,
                            acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath,
                            dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let target = itemAt(indexPath),
                  let urls = draggingInfo.draggingPasteboard
                      .readObjects(forClasses: [NSURL.self]) as? [URL],
                  !urls.isEmpty else { return false }
            model.acceptDrop(urls, into: target.url, copy: false)
            return true
        }
    }
}

/// Collection view that routes right-clicks to the shared menus.
final class GridCollectionView: NSCollectionView {
    weak var coordinator: IconGridView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        coordinator?.focusPaneFromMouse()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        coordinator?.focusPaneFromMouse()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return coordinator?.menu(at: point, in: self)
    }
}

/// One grid cell: thumbnail/icon + a two-line centred label; selection is a
/// rounded accent behind the label (Finder-style).
final class IconItem: NSCollectionViewItem, NSTextFieldDelegate {
    static let reuseID = NSUserInterfaceItemIdentifier("anf.icon.item")

    private let icon = NSImageView()
    private let label = NSTextField(wrappingLabelWithString: "")
    private let labelBackdrop = NSView()
    private let tagDot = NSView()   // Finder colour tag, top-trailing of the icon
    private var iconW: NSLayoutConstraint?
    private var iconH: NSLayoutConstraint?
    private var currentID: FileItem.ID?
    private var renameCommit: ((String) -> Void)?
    private var renameCancel: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func loadView() {
        view = DoubleClickView { [weak self] in self?.onDoubleClick?() }

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        labelBackdrop.translatesAutoresizingMaskIntoConstraints = false
        labelBackdrop.wantsLayer = true
        labelBackdrop.layer?.cornerRadius = 5
        labelBackdrop.layer?.cornerCurve = .continuous

        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.maximumNumberOfLines = 2
        label.cell?.truncatesLastVisibleLine = true
        label.isEditable = false
        label.isBordered = false
        label.drawsBackground = false
        label.delegate = self

        tagDot.translatesAutoresizingMaskIntoConstraints = false
        tagDot.wantsLayer = true
        tagDot.layer?.cornerRadius = 5
        tagDot.layer?.borderWidth = 1.5
        tagDot.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        tagDot.isHidden = true

        view.addSubview(icon)
        view.addSubview(labelBackdrop)
        view.addSubview(label)
        view.addSubview(tagDot)
        iconW = icon.widthAnchor.constraint(equalToConstant: 84)
        iconH = icon.heightAnchor.constraint(equalToConstant: 84)
        NSLayoutConstraint.activate([
            iconW!, iconH!,
            icon.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            tagDot.widthAnchor.constraint(equalToConstant: 10),
            tagDot.heightAnchor.constraint(equalToConstant: 10),
            tagDot.trailingAnchor.constraint(equalTo: icon.trailingAnchor, constant: -1),
            tagDot.topAnchor.constraint(equalTo: icon.topAnchor, constant: 1),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 5),
            label.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 2),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -2),
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            labelBackdrop.leadingAnchor.constraint(equalTo: label.leadingAnchor, constant: -6),
            labelBackdrop.trailingAnchor.constraint(equalTo: label.trailingAnchor, constant: 6),
            labelBackdrop.topAnchor.constraint(equalTo: label.topAnchor, constant: -2),
            labelBackdrop.bottomAnchor.constraint(equalTo: label.bottomAnchor, constant: 2),
        ])
    }

    func configure(with item: FileItem, iconSide: Double) {
        currentID = item.id
        label.stringValue = item.name
        iconW?.constant = iconSide
        iconH?.constant = iconSide
        // One cache lookup, not two (this runs per cell on every scroll frame).
        let cachedThumb = ThumbnailProvider.shared.cached(for: item, side: iconSide * 2)
        icon.image = cachedThumb ?? IconProvider.shared.icon(for: item)

        if item.supportsThumbnail, cachedThumb == nil {
            let id = item.id
            Task { [weak self] in
                guard let thumb = await ThumbnailProvider.shared.thumbnail(for: item, side: iconSide * 2),
                      let self, self.currentID == id else { return }
                self.icon.image = thumb
            }
        }
        if let tag = FileTags.primaryColor(of: item.url) {
            tagDot.layer?.backgroundColor = tag.cgColor
            tagDot.isHidden = false
        } else {
            tagDot.isHidden = true
        }
        applySelectionStyle()
    }

    override var isSelected: Bool {
        didSet { applySelectionStyle() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentID = nil
        endRenameUI()
    }

    private func applySelectionStyle() {
        labelBackdrop.layer?.backgroundColor = isSelected
            ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        label.textColor = isSelected ? .white : .labelColor
    }

    // MARK: Inline rename

    func beginRename(onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        renameCommit = onCommit
        renameCancel = onCancel
        label.isEditable = true
        view.window?.makeFirstResponder(label)
        if let editor = label.currentEditor() {
            let ns = label.stringValue as NSString
            let extLen = (ns.pathExtension as NSString).length
            let baseLen = extLen > 0 ? ns.length - extLen - 1 : ns.length
            editor.selectedRange = NSRange(location: 0, length: max(0, baseLen))
        }
    }

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            let cancel = renameCancel
            endRenameUI()
            cancel?()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let commit = renameCommit else { return }
        let value = label.stringValue
        endRenameUI()
        commit(value)
        view.window?.makeFirstResponder(view.superview)
    }

    private func endRenameUI() {
        renameCommit = nil
        renameCancel = nil
        label.isEditable = false
    }
}

/// Group header shown above each section when Arrange-by is active: a bottom-
/// aligned, semibold secondary label matching the list view's group headers.
final class GridSectionHeader: NSView {
    static let reuseID = NSUserInterfaceItemIdentifier("anf.grid.header")
    private let label = NSTextField(labelWithString: "")
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        identifier = Self.reuseID
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isBordered = false; label.drawsBackground = false
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ text: String) { label.stringValue = text }
}

/// Plain container that forwards double-clicks (single-click selection is
/// handled by the collection view's own mouse tracking via super).
private final class DoubleClickView: NSView {
    private let onDouble: () -> Void
    init(onDouble: @escaping () -> Void) {
        self.onDouble = onDouble
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if event.clickCount == 2 { onDouble() }
    }
}
