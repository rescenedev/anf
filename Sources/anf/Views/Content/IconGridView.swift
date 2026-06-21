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

        /// Is the item at `ip` part of the current model selection? Used by the grid
        /// to decide whether a plain click should defer its collapse-to-one (#76).
        func isSelected(_ ip: IndexPath) -> Bool {
            guard let id = itemAt(ip)?.id else { return false }
            return model.selection.contains(id)
        }

        func urls(for indexPaths: Set<IndexPath>) -> [URL] {
            indexPaths.compactMap { itemAt($0)?.url }
        }

        func dragSources(for indexPaths: Set<IndexPath>) -> [(IndexPath, URL)] {
            indexPaths.compactMap { ip in itemAt(ip).map { (ip, $0.url) } }
        }

        func openItem(at point: NSPoint, in cv: NSCollectionView) {
            guard let ip = cv.indexPathForItem(at: point), let item = itemAt(ip) else { return }
            model.open(item)
        }

        func openItem(at ip: IndexPath) {
            guard let item = itemAt(ip) else { return }
            model.open(item)
        }

        func setDragging(_ dragging: Bool) { isDragging = dragging }

        /// Mouse click selection — AppKit's built-in path breaks with custom item
        /// views, so we drive model + highlight ourselves.
        func click(at ip: IndexPath, modifiers: NSEvent.ModifierFlags, in cv: NSCollectionView) {
            guard let item = itemAt(ip) else { return }
            let newIDs: Set<FileItem.ID>
            if modifiers.contains(.command) {
                newIDs = model.selection.contains(item.id)
                    ? model.selection.subtracting([item.id])
                    : model.selection.union([item.id])
            } else if modifiers.contains(.shift),
                      let anchor = model.selectionCursorIndex {
                let lo = min(anchor, flatIndex(ip) ?? anchor)
                let hi = max(anchor, flatIndex(ip) ?? anchor)
                newIDs = Set(items[lo...hi].map(\.id))
            } else {
                newIDs = [item.id]
            }
            applySelection(newIDs, in: cv)
            if newIDs == [item.id] { model.select(item) }
        }

        func syncSelectionFromView(_ cv: NSCollectionView) { pushSelection(cv) }

        /// Push an explicit selection into the model and repaint visible cells.
        /// Don't read `cv.selectionIndexPaths` after `selectItems` — with custom
        /// item views AppKit often never updates it, which cleared selection (#76).
        func applySelection(_ ids: Set<FileItem.ID>, in cv: NSCollectionView) {
            syncState.recordApplied(ids)
            if ids != model.selection { model.selection = ids }
            let paths = Set(ids.compactMap { id in model.index(of: id).flatMap { indexPath(forFlat: $0) } })
            syncState.applying {
                cv.deselectItems(at: cv.selectionIndexPaths.subtracting(paths))
                if !paths.isEmpty { cv.selectItems(at: paths, scrollPosition: []) }
                else { cv.deselectItems(at: cv.selectionIndexPaths) }
            }
            refreshSelectionHighlight(in: cv)
        }

        /// Drive the label backdrop from the model — `isSelected` is unreliable with
        /// our custom item views, so we paint selection ourselves.
        func refreshSelectionHighlight(in cv: NSCollectionView) {
            let selected = model.selection
            for section in 0..<cv.numberOfSections {
                for item in 0..<cv.numberOfItems(inSection: section) {
                    let ip = IndexPath(item: item, section: section)
                    guard let cell = cv.item(at: ip) as? IconItem,
                          let file = itemAt(ip) else { continue }
                    cell.setHighlighted(selected.contains(file.id))
                }
            }
        }

        func indexPaths(for ids: Set<FileItem.ID>) -> Set<IndexPath> {
            Set(ids.compactMap { id in model.index(of: id).flatMap { indexPath(forFlat: $0) } })
        }

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
            if isDragging {
                // Never reload mid-drag — a reloadData rebuilds the items and
                // cancels the drag session. The pending itemsVersion is picked up
                // by the next sync once the drag ends (#76).
            } else if syncState.itemsChanged(version: model.itemsVersion) {
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
            guard syncState.selectionChanged(model.selection, force: force) else {
                refreshSelectionHighlight(in: cv)
                return
            }
            let want = Set(model.selection.compactMap { id in
                model.index(of: id).flatMap { indexPath(forFlat: $0) }
            })
            guard want != cv.selectionIndexPaths else {
                refreshSelectionHighlight(in: cv)
                return
            }
            syncState.applying {
                cv.deselectItems(at: cv.selectionIndexPaths)
                cv.selectItems(at: want, scrollPosition: [])
            }
            refreshSelectionHighlight(in: cv)
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
                cell.setHighlighted(model.selection.contains(item.id))
            }
            if let root = cell.view as? IconCellRootView {
                root.grid = collectionView as? GridCollectionView
            }
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView,
                            viewForSupplementaryElementOfKind kind: String,
                            at indexPath: IndexPath) -> NSView {
            // During a drag the flow layout asks for an inter-item gap indicator.
            // We don't draw one, and dequeuing it with the section-header identifier
            // threw NSInternalInconsistencyException mid-drag — which silently
            // cancelled EVERY grid drag, so dragged icons never moved (#76). Only
            // the section header is ours; hand back an empty view for anything else.
            guard kind == NSCollectionView.elementKindSectionHeader else { return NSView() }
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
            guard !syncState.isSyncing else { return }
            guard !indexPaths.isEmpty else {
                refreshSelectionHighlight(in: collectionView)
                return
            }
            let ids = Set(indexPaths.compactMap { itemAt($0)?.id })
            syncState.recordApplied(ids)
            if ids != model.selection { model.selection = ids }
            refreshSelectionHighlight(in: collectionView)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            didDeselectItemsAt indexPaths: Set<IndexPath>) {
            pushSelection(collectionView)
            refreshSelectionHighlight(in: collectionView)
        }

        private func pushSelection(_ cv: NSCollectionView) {
            guard !syncState.isSyncing else { return }
            let ids = Set(cv.selectionIndexPaths.compactMap { itemAt($0)?.id })
            // Custom item views often leave selectionIndexPaths empty even after
            // selectItems — never push that back into the model (#76).
            guard !ids.isEmpty || model.selection.isEmpty else {
                refreshSelectionHighlight(in: cv)
                return
            }
            syncState.recordApplied(ids)
            if ids != model.selection { model.selection = ids }
            refreshSelectionHighlight(in: cv)
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

        // A registered drop destination that rejects everything SWALLOWS the drag
        // (the SwiftUI fallback behind it never fires), so pane-to-pane copy/move
        // silently failed in ICON mode while it worked in list mode (#73 follow-up).
        // Drop ON a folder → into that folder; anywhere else → into the current
        // folder (whole-pane drop), mirroring FileListView.
        func collectionView(_ collectionView: NSCollectionView,
                            validateDrop draggingInfo: NSDraggingInfo,
                            proposedIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
                            dropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>) -> NSDragOperation {
            guard draggingInfo.draggingPasteboard
                    .canReadObject(forClasses: [NSURL.self], options: nil) else { return [] }
            let path = proposedIndexPath.pointee as IndexPath
            // Drop ON a folder → into it. Anything else → flip to a between-items
            // drop (whole-pane → current folder). Keep AppKit's proposed index
            // path untouched; overwriting it with an out-of-range index made the
            // collection view reject the drop entirely (#76).
            if !(dropOperation.pointee == .on && isDropFolder(itemAt(path))) {
                dropOperation.pointee = .before
            }
            return dropOp(draggingInfo)
        }

        func collectionView(_ collectionView: NSCollectionView,
                            acceptDrop draggingInfo: NSDraggingInfo,
                            indexPath: IndexPath,
                            dropOperation: NSCollectionView.DropOperation) -> Bool {
            guard let urls = draggingInfo.draggingPasteboard
                      .readObjects(forClasses: [NSURL.self], options: nil) as? [URL],
                  !urls.isEmpty else { return false }
            let dropFolder = (dropOperation == .on && isDropFolder(itemAt(indexPath)))
                ? itemAt(indexPath) : nil
            let into: URL = dropFolder?.url ?? model.currentURL
            // Drop the valid items; silently skip only a folder dropped onto itself
            // or into its own subtree (rejecting the whole batch lost the good items
            // too). standardizedFileURL closes the symlink/trailing-slash hole.
            let intoPath = into.standardizedFileURL.path
            let valid = urls.filter {
                let p = $0.standardizedFileURL.path
                return intoPath != p && !intoPath.hasPrefix(p + "/")
            }
            guard !valid.isEmpty else { return false }
            model.acceptDrop(valid, into: into, copy: copyRequested(draggingInfo))
            return true
        }

        /// A folder that accepts a drop INTO it — never the synthetic ".." row.
        private func isDropFolder(_ item: FileItem?) -> Bool {
            guard let item else { return false }
            return item.isBrowsableContainer && !item.isParentRef
        }

        /// Default COPY; ⌘ requests MOVE — but never move a copy-only source (a drag
        /// from another app whose mask is .copy), which would delete its original.
        /// Only honor move when the source actually permits move/generic, so the
        /// performed op can't diverge from the copy badge dropOp() reports (#76).
        private func copyRequested(_ info: NSDraggingInfo) -> Bool {
            let mask = info.draggingSourceOperationMask
            guard NSEvent.modifierFlags.contains(.command),
                  mask.contains(.move) || mask.contains(.generic) else { return true }
            return false
        }

        /// Operation to REPORT to AppKit, clamped to the (modifier-adjusted) source
        /// mask so an empty intersection never rejects the drop. ⌘ collapses the
        /// mask to `.generic`; we report that and still move via `copyRequested`.
        private func dropOp(_ info: NSDraggingInfo) -> NSDragOperation {
            let allowed = info.draggingSourceOperationMask
            let want: NSDragOperation = copyRequested(info) ? .copy : .move
            return allowed.contains(want) ? want : allowed
        }

        /// True between drag-session begin/end. `sync()` skips its `reloadData`
        /// while set, so a folder change that lands mid-drag can't rebuild the
        /// grid and cancel the drag (#76).
        private(set) var isDragging = false

        func collectionView(_ collectionView: NSCollectionView,
                            draggingSession session: NSDraggingSession,
                            willBeginAt screenPoint: NSPoint,
                            forItemsAt indexPaths: Set<IndexPath>) {
            isDragging = true
        }

        func collectionView(_ collectionView: NSCollectionView,
                            draggingSession session: NSDraggingSession,
                            endedAt screenPoint: NSPoint,
                            dragOperation operation: NSDragOperation) {
            isDragging = false
        }
    }
}

/// Collection view: manual file drag (custom item views break AppKit's built-in
/// collection drag — only rubber-band selection fires). Drops still use delegate.
final class GridCollectionView: NSCollectionView {
    weak var coordinator: IconGridView.Coordinator?

    private var dragAnchor: NSPoint?
    private var dragIndexPaths: Set<IndexPath>?
    private var fileDragStarted = false
    /// A plain click on an already-selected item in a multi-selection defers its
    /// collapse-to-one until mouse-up, so a drag can move the whole selection (#76).
    private var pendingCollapseIP: IndexPath?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Item-cell click — index path comes from the item, not hit-test (which
    /// breaks when the event is forwarded from IconCellRootView).
    func itemMouseDown(at ip: IndexPath, event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        dragAnchor = pt
        fileDragStarted = false
        pendingCollapseIP = nil

        if event.clickCount == 2 {
            coordinator?.openItem(at: ip)
            dragIndexPaths = nil
            return
        }

        let mods = event.modifierFlags.intersection([.command, .shift])
        if let coord = coordinator, mods.isEmpty,
           coord.isSelected(ip), coord.model.selection.count > 1 {
            // Plain click on an already-selected item within a multi-selection: keep
            // the whole selection so a drag moves them all, and defer the collapse to
            // a single item until mouse-up (Finder / NSTableView behavior) (#76).
            dragIndexPaths = coord.indexPaths(for: coord.model.selection)
            pendingCollapseIP = ip
        } else {
            coordinator?.click(at: ip, modifiers: event.modifierFlags, in: self)
            if let coord = coordinator {
                let paths = coord.indexPaths(for: coord.model.selection)
                dragIndexPaths = paths.isEmpty ? [ip] : paths
            } else {
                dragIndexPaths = [ip]
            }
        }
    }

    func itemMouseDragged(with event: NSEvent) {
        trackItemDrag(with: event)
    }

    func itemMouseUp(with event: NSEvent) {
        // No drag happened — complete the deferred collapse to the clicked item.
        if !fileDragStarted, let ip = pendingCollapseIP {
            coordinator?.click(at: ip, modifiers: [], in: self)
        }
        dragAnchor = nil
        dragIndexPaths = nil
        fileDragStarted = false
        pendingCollapseIP = nil
        coordinator?.focusPaneFromMouse()
    }

    override func mouseDown(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        // Clicks on cells are handled by IconCellRootView → itemMouseDown.
        if let ip = indexPathForItem(at: pt) {
            itemMouseDown(at: ip, event: event)
            return
        }

        dragAnchor = pt
        fileDragStarted = false
        dragIndexPaths = nil
        pendingCollapseIP = nil
        if !event.modifierFlags.contains(.shift) {
            coordinator?.applySelection([], in: self)
        }
        super.mouseDown(with: event)   // rubber-band on empty area only
    }

    override func mouseDragged(with event: NSEvent) {
        if trackItemDrag(with: event) { return }
        super.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        dragAnchor = nil
        dragIndexPaths = nil
        fileDragStarted = false
        pendingCollapseIP = nil
        super.mouseUp(with: event)
        coordinator?.focusPaneFromMouse()
    }

    /// Returns true when a file drag session started (caller should skip super).
    @discardableResult
    private func trackItemDrag(with event: NSEvent) -> Bool {
        guard !fileDragStarted, let anchor = dragAnchor, let paths = dragIndexPaths, !paths.isEmpty else {
            return false
        }
        let pt = convert(event.locationInWindow, from: nil)
        let dx = pt.x - anchor.x, dy = pt.y - anchor.y
        if dx * dx + dy * dy >= 36, beginFileDrag(indexPaths: paths, event: event) {
            fileDragStarted = true
            dragAnchor = nil
            dragIndexPaths = nil
            pendingCollapseIP = nil   // a drag started — don't collapse on mouse-up
            return true
        }
        return false
    }

    override func rightMouseDown(with event: NSEvent) {
        coordinator?.focusPaneFromMouse()
        super.rightMouseDown(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        return coordinator?.menu(at: point, in: self)
    }

    @discardableResult
    private func beginFileDrag(indexPaths: Set<IndexPath>, event: NSEvent) -> Bool {
        guard let coord = coordinator else { return false }
        let sources = coord.dragSources(for: indexPaths)
        guard !sources.isEmpty else { return false }
        let anchor = convert(event.locationInWindow, from: nil)
        var draggingItems: [NSDraggingItem] = []
        for (ip, url) in sources {
            let di = NSDraggingItem(pasteboardWriter: url as NSURL)
            // EVERY selected URL must reach the pasteboard regardless of scroll
            // position — item(at:) is nil for recycled/off-screen cells, and dropping
            // only the visible ones silently lost part of a multi-selection (#76 data
            // loss, worse on move). The cell snapshot is purely the drag image; the
            // frame is in THIS view's coords so it follows the cursor.
            if let cell = item(at: ip) {
                let cellView = cell.view
                let frame = cellView.convert(cellView.bounds, to: self)
                di.setDraggingFrame(frame, contents: cellView.dragSnapshot())
            } else {
                di.setDraggingFrame(NSRect(x: anchor.x, y: anchor.y, width: 1, height: 1), contents: nil)
            }
            draggingItems.append(di)
        }
        guard !draggingItems.isEmpty else { return false }
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.draggingFormation = NSDraggingFormation.pile
        session.animatesToStartingPositionsOnCancelOrFail = true
        coord.setDragging(true)
        return true
    }

    override func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        switch context {
        case .outsideApplication: return .copy
        default:
            return NSEvent.modifierFlags.contains(.command) ? [.move, .generic] : [.copy, .move, .generic]
        }
    }

    override func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint,
                         operation: NSDragOperation) {
        coordinator?.setDragging(false)
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

    override func loadView() {
        view = IconCellRootView()

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

    private var highlighted = false

    override var isSelected: Bool {
        didSet {
            // Visual selection comes from setHighlighted(_:) driven by the model.
            // AppKit's isSelected is unreliable with our custom item views (#76).
        }
    }

    func setHighlighted(_ on: Bool) {
        highlighted = on
        labelBackdrop.layer?.backgroundColor = on
            ? NSColor.controlAccentColor.cgColor : NSColor.clear.cgColor
        label.textColor = on ? .white : .labelColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentID = nil
        highlighted = false
        endRenameUI()
    }

    private func applySelectionStyle() {
        setHighlighted(highlighted)
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

/// Claim the whole cell for hit-testing and forward mouse to the grid.
private final class IconCellRootView: NSView {
    weak var grid: GridCollectionView?

    private var isRenaming: Bool {
        subviews.contains(where: { ($0 as? NSTextField)?.isEditable == true })
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        wireGridIfNeeded()
    }

    private func wireGridIfNeeded() {
        guard grid == nil else { return }
        var v: NSView? = self
        while let cur = v {
            if let g = cur as? GridCollectionView { grid = g; return }
            v = cur.superview
        }
    }

    private func forwardingGrid() -> GridCollectionView? {
        if let grid { return grid }
        wireGridIfNeeded()
        return grid
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isRenaming { return super.hitTest(point) }
        // `point` arrives in the SUPERVIEW's coordinate system, not ours. Testing
        // it against local `bounds` (origin 0,0) only matched cells near the
        // collection-view origin; every other cell returned nil, so its click fell
        // through to the collection view, which couldn't map the point to an item
        // → click selection and drag were dead in grid mode (#76). Convert first.
        guard let superview else { return bounds.contains(point) ? self : nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    private func owningItem() -> IconItem? {
        var r: NSResponder? = self
        while let cur = r {
            if let item = cur as? IconItem { return item }
            r = cur.nextResponder
        }
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        if isRenaming { super.mouseDown(with: event); return }
        guard let grid = forwardingGrid(), let item = owningItem(), let ip = grid.indexPath(for: item) else { return }
        grid.itemMouseDown(at: ip, event: event)
    }

    override func mouseDragged(with event: NSEvent) {
        if isRenaming { super.mouseDragged(with: event); return }
        forwardingGrid()?.itemMouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        if isRenaming { super.mouseUp(with: event); return }
        forwardingGrid()?.itemMouseUp(with: event)
    }
}

private extension NSView {
    /// A bitmap snapshot of the view, used as the drag image so the icon follows
    /// the cursor during a file drag (#76).
    func dragSnapshot() -> NSImage? {
        guard bounds.width > 0, bounds.height > 0,
              let rep = bitmapImageRepForCachingDisplay(in: bounds) else { return nil }
        cacheDisplay(in: bounds, to: rep)
        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        return image
    }
}
