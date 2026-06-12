import AppKit
import Quartz
import WebKit

/// Global keyboard dispatch for the whole app, driven by a local event monitor.
/// This is the single source of truth for shortcuts (orthodox / Finder / Explorer
/// style) and avoids fighting the SwiftUI ⇄ AppKit responder chain. While a text
/// field is being edited, everything passes straight through so typing works.
@MainActor
final class KeyboardController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    /// The workspace of the window the user is actually in — resolved per event
    /// so one shared monitor drives every window correctly. `nil` only between
    /// the last window closing and the app quitting.
    private var workspace: WorkspaceModel! { WindowRegistry.current }
    private var monitor: Any?
    /// The key window owns its palette (see AnfWindowController), so ⌘K targets
    /// that window and the palette dies with it — no per-workspace cache to leak
    /// or collide on ObjectIdentifier reuse.
    private var palette: CommandPaletteController? { WindowRegistry.currentController?.palette }

    /// Physical keycode → Latin letter, so ⌘-letter shortcuts work under any
    /// input source (Korean IME makes `charactersIgnoringModifiers` return e.g.
    /// "ㅏ" for the K key — keycode 40 stays constant).
    private static let latinLetter: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c",
        9: "v", 11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 40: "k",
        45: "n", 46: "m",
    ]

    override init() {
        super.init()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.workspace != nil else { return event }
            return self.handle(event) ? nil : event
        }
    }

    private var model: BrowserModel { workspace.active }

    private var isEditingText: Bool {
        let responder = NSApp.keyWindow?.firstResponder
        return responder is NSText || responder is NSTextView
    }

    /// True when the embedded xterm.js terminal (WKWebView) has focus.
    private var isTerminalFocused: Bool {
        var responder = NSApp.keyWindow?.firstResponder as? NSView
        while let view = responder {
            if view is WKWebView { return true }
            responder = view.superview
        }
        return false
    }

    /// Returns true if the event was consumed.
    private func handle(_ e: NSEvent) -> Bool {
        let flagsAll = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // ⌃` toggles the terminal even while it's focused.
        if flagsAll == .control && e.keyCode == 50 { workspace.toggleTerminal(); return true }
        // ⌘+/- adjusts terminal font size even while terminal is focused.
        if isTerminalFocused {
            let tFlags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
            if tFlags == .command {
                let tChars = e.charactersIgnoringModifiers ?? ""
                if tChars == "=" || tChars == "+" { workspace.bumpTerminalFontSize(1); return true }
                if tChars == "-" { workspace.bumpTerminalFontSize(-1); return true }
            }
            return false
        }
        if isEditingText { return false }

        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let cmd = flags.contains(.command)
        let shift = flags.contains(.shift)
        let opt = flags.contains(.option)
        let ctrl = flags.contains(.control)
        let code = e.keyCode

        // ⌃Tab / ⌃⇧Tab → cycle tabs within the active pane (plain Tab = pane).
        if ctrl, code == 48 {
            workspace.activePaneModel.cycle(shift ? -1 : 1)
            return true
        }
        // Resolve letter keys by physical keycode (input-source independent), so
        // ⌘K works under the Korean IME too. Lowercased fallback handles Shift
        // (charactersIgnoringModifiers yields "D"/"G"/"N") and symbol keys.
        let chars = Self.latinLetter[code] ?? (e.charactersIgnoringModifiers ?? "").lowercased()

        // Vertical step: a full grid row in the icon grid; one item in the
        // gallery filmstrip (a single horizontal row) and in list/columns.
        let gridStep = model.viewMode == .icons ? max(1, model.gridColumns) : 1

        // --- No-modifier keys (orthodox navigation) ---
        if !cmd && !opt {
            switch code {
            case 49: toggleQuickLook(); return true                 // space
            case 36, 76: model.beginRename(); return true           // return / enter → inline rename
            case 48: workspace.cyclePane(shift ? -1 : 1); return true // Tab → switch pane
            case 125:   // ↓ — icon/gallery grids jump a whole row
                model.moveSelection(by: gridStep, extend: shift); return true
            case 126:   // ↑
                model.moveSelection(by: -gridStep, extend: shift); return true
            // ←/→ move the selection in icon/gallery grids (no native arrow
            // handling there). In list/columns they fall through to the native
            // view. Folder history stays on ⌘←/⌘→.
            case 123:
                if model.viewMode == .icons || model.viewMode == .gallery {
                    model.moveSelection(by: -1, extend: shift); return true
                }
                return false
            case 124:
                if model.viewMode == .icons || model.viewMode == .gallery {
                    model.moveSelection(by: 1, extend: shift); return true
                }
                return false
            case 51:  model.trashSelection(); return true           // delete → trash
            // PgUp/PgDn move the SELECTION a viewport's worth (Explorer-style —
            // works even when there's nothing to scroll); Home/End jump it to
            // the first/last item. The views scroll to follow the selection.
            case 116: model.moveSelection(by: -pageRows(), extend: shift); return true
            case 121: model.moveSelection(by: pageRows(), extend: shift); return true
            case 115: model.moveSelection(by: -model.items.count, extend: shift); return true
            case 119: model.moveSelection(by: model.items.count, extend: shift); return true
            case 96:  workspace.transferToOtherPane(move: false); return true // F5 copy
            case 97:  workspace.transferToOtherPane(move: true); return true   // F6 move
            case 53:  if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil); return true } // esc
            default: break
            }
            // Type-to-select (Finder typeahead): plain printable keys jump the
            // selection to the first item matching the typed prefix. Function
            // keys land in the U+F700 private-use block; skip those. The
            // physical key's latin letter rides along as a fallback so the
            // Korean IME ("ㅊ" for the C key) still finds latin names.
            if !ctrl, let typed = e.characters, !typed.isEmpty,
               typed.unicodeScalars.allSatisfy({ $0.value > 0x20 && !(0xF700...0xF8FF).contains($0.value) }) {
                model.typeSelect(typed, fallback: Self.latinLetter[code])
                return true
            }
        }

        // --- Command combinations ---
        if cmd {
            if opt {
                // ⌘⌥C copies the selection's path; ⌥⇧⌘C the current folder's.
                if chars == "c" {
                    shift ? model.copyCurrentFolderPath() : model.copyPathToPasteboard()
                    return true
                }
                // Tab selection ⌘⌥1…⌘⌥9
                if let n = Int(chars), (1...9).contains(n) {
                    workspace.activePaneModel.select(n - 1); return true
                }
            }
            // ⌘1–4 → pane layout (single / dual / rows / quad).
            if !opt {
                let digit: Int? = [18: 1, 19: 2, 20: 3, 21: 4][Int(code)]
                if let d = digit {
                    workspace.setLayout([.single, .dual, .rows, .quad][d - 1])
                    return true
                }
            }
            switch chars {
            case "z":
                // ⌘Z undo / ⌘⇧Z redo file operations, then refresh every visible
                // pane — the change may affect folders shown in other panes.
                let did = shift ? FileUndo.shared.redo() : FileUndo.shared.undo()
                if did { workspace.panes.prefix(workspace.layout.count).forEach { $0.current.reload() } }
                else { NSSound.beep() }
                return true
            case "t": workspace.activePaneModel.newTab(); return true
            case "w":
                // Close the current tab → pane → window (Finder/browser order).
                let pane = workspace.activePaneModel
                if pane.tabs.count > 1 { pane.closeCurrent() }
                else if workspace.layout.count > 1 { workspace.closeActivePane() }
                else { NSApp.keyWindow?.performClose(nil) }   // last tab+pane → close window
                return true
            case "=", "+": bumpScale(1); return true
            case "-": bumpScale(-1); return true
            case "c": model.copySelectionToPasteboard(); return true
            case "x": model.cutSelectionToPasteboard(); return true
            case "v": model.pasteFromPasteboard(); return true
            case "a": model.selectAll(); return true
            case "i": workspace.inspectorVisible.toggle(); return true
            case "/": workspace.pathBarVisible.toggle(); workspace.save(); return true
            case "d": shift ? workspace.toggleFavoriteCurrent() : model.duplicateSelection(); return true
            case "l": model.goToFolderPrompt(); return true
            case "p": palette?.toggle(); return true
            case "k": palette?.toggle(); return true   // ⌘K command palette
            case "g": if shift { model.goToFolderPrompt(); return true }
            case "n": if shift { model.makeNewFolder(); return true }
            case "r": model.reload(); return true
            default: break
            }
            switch code {
            case 47:  // ⌘⇧. — toggle hidden files (Finder parity)
                if shift { model.showHidden.toggle(); return true }
                return false
            case 123: model.goBack(); refocusContent(); return true     // ⌘← history back
            case 124: model.goForward(); refocusContent(); return true  // ⌘→ history forward
            case 125: model.openSelected(); return true   // ⌘↓ open
            case 126: model.goUp(); refocusContent(); return true // ⌘↑ enclosing folder
            case 51:  model.trashSelection(); return true // ⌘⌫ trash
            case 33:  // [ — ⌘[ view mode back, ⌘⇧[ toggle LEFT sidebar
                if shift { toggleLeftSidebar() } else { cycleViewMode(-1) }
                return true
            case 30:  // ] — ⌘] view mode forward, ⌘⇧] toggle RIGHT sidebar (inspector)
                if shift { workspace.inspectorVisible.toggle() } else { cycleViewMode(1) }
                return true
            default: break
            }
        }
        return false
    }

    /// Items per PgUp/PgDn step: one viewport's worth of rows in the current
    /// view (× columns in the icon grid), derived from the live scroll view.
    private func pageRows() -> Int {
        guard let scroll = model.contentScrollView, scroll.window != nil else { return 10 }
        let h = scroll.contentView.bounds.height
        if let table = scroll.documentView as? NSTableView {
            return max(1, Int(h / (table.rowHeight + table.intercellSpacing.height)) - 1)
        }
        if let cv = scroll.documentView as? NSCollectionView,
           let layout = cv.collectionViewLayout as? NSCollectionViewFlowLayout {
            let rows = max(1, Int(h / (layout.itemSize.height + layout.minimumLineSpacing)) - 1)
            return rows * max(1, model.gridColumns)
        }
        return 10
    }

    /// ⌘[ / ⌘] cycles the active tab's view mode (list / icons / columns / …).
    private func cycleViewMode(_ dir: Int) {
        let all = ViewMode.allCases
        guard let i = all.firstIndex(of: model.viewMode) else { return }
        model.viewMode = all[(i + dir + all.count) % all.count]
    }

    /// ⌘⇧[ toggles the native left sidebar (the split item).
    private func toggleLeftSidebar() {
        guard let split = NSApp.keyWindow?.anfSplitViewController,
              let item = split.splitViewItems.first else { return }
        item.animator().isCollapsed.toggle()
        workspace.sidebarVisible = !item.isCollapsed
    }

    /// ⌘+ / ⌘−: when the inspector is showing a plain-text preview, scale its
    /// font; otherwise scale the file listing as before.
    private func bumpScale(_ direction: Int) {
        if workspace.inspectorVisible,
           let target = model.selectedItems.first,
           target.isPlainTextLike || target.isExtractableDocument {
            workspace.bumpPreviewTextSize(direction)
        } else {
            model.bumpScale(direction)
        }
    }

    // MARK: - Focus

    /// After navigation the first responder can be (or stay) in the sidebar, so
    /// the keyboard focus ring lands on a sidebar row. Pull focus back to the
    /// first file table on the content side of the split.
    private func refocusContent() {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow,
                  let split = window.anfSplitViewController,
                  split.splitViewItems.count > 1 else { return }
            let contentRoot = split.splitViewItems[1].viewController.view
            if let fr = window.firstResponder as? NSView, fr.isDescendant(of: contentRoot) {
                return   // focus already lives in the content area
            }
            if let table = Self.firstTableView(in: contentRoot) {
                window.makeFirstResponder(table)
            }
        }
    }

    private static func firstTableView(in root: NSView) -> NSTableView? {
        var queue: [NSView] = [root]
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let table = view as? NSTableView { return table }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }

    // MARK: - Quick Look

    private var previewURLs: [URL] {
        let sel = model.selectedItems.map(\.url)
        if !sel.isEmpty { return sel }
        if let first = model.items.first { return [first.url] }
        return []
    }

    private func toggleQuickLook() {
        guard !previewURLs.isEmpty, let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() && panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.dataSource = self
            panel.delegate = self
            panel.makeKeyAndOrderFront(nil)
            panel.reloadData()
        }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { previewURLs.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        previewURLs[index] as NSURL
    }
}
