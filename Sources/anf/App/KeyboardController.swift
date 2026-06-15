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
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .otherMouseDown]) { [weak self] event in
            guard let self, self.workspace != nil else { return event }
            // Stand down while a modal alert/sheet (or the palette overlay) owns
            // input. NSAlert.runModal sets NSApp.modalWindow; without this the
            // monitor would consume the alert's keys — e.g. Return mapped to
            // rename swallowed the Enter that should hit a confirm dialog's
            // default button, so the delete-confirm only worked by mouse.
            if InputGate.modalActive
                || NSApp.modalWindow != nil
                || NSApp.keyWindow?.attachedSheet != nil {
                return event
            }
            if event.type == .otherMouseDown {
                return self.handleMouse(event) ? nil : event
            }
            return self.handle(event) ? nil : event
        }
    }

    /// Mouse side buttons: button 3 → Back, button 4 → Forward (the de-facto
    /// browser/Finder mapping). Other buttons pass through untouched.
    private func handleMouse(_ e: NSEvent) -> Bool {
        guard !isEditingText, !isTerminalFocused else { return false }
        switch e.buttonNumber {
        case 3: model.goBack(); refocusContent(); return true
        case 4: model.goForward(); refocusContent(); return true
        default: return false
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
        let token = Keymap.token(keyCode: e.keyCode, fallback: e.charactersIgnoringModifiers)
        let bound = Keymap.shared.action(flags: flagsAll, key: token)
        // The terminal toggle works even while the terminal is focused (its
        // factory chord ⌃` did; a rebound chord keeps that property).
        if bound == .toggleTerminal { workspace.toggleTerminal(); return true }
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
        // Keymap-driven actions (defaults pre-filled in keybindings.json; ⌘,
        // opens it). Everything bindable dispatches here; the hardcoded
        // shortcuts below are the non-bindable navigation/system set.
        if let bound { return dispatch(bound) }

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

        // --- No-modifier keys (orthodox navigation; not remappable) ---
        // space/return/delete/F5/F6 moved to the keymap dispatch above.
        if !cmd && !opt {
            switch code {
            case 48: workspace.cyclePane(shift ? -1 : 1); return true // Tab → switch pane
            case 125:   // ↓ — icon grid jumps a whole row (falls back to next
                        // item when there's no row below: single/last row)
                moveSel(by: gridStep, extend: shift, rowJump: model.viewMode == .icons); return true
            case 126:   // ↑
                moveSel(by: -gridStep, extend: shift, rowJump: model.viewMode == .icons); return true
            // ←/→ move the selection in icon/gallery grids (no native arrow
            // handling there). In list/columns they fall through to the native
            // view. Folder history stays on ⌘←/⌘→.
            case 123:
                if model.viewMode == .icons || model.viewMode == .gallery {
                    moveSel(by: -1, extend: shift); return true
                }
                // List: ← collapses the selected folder; on a nested row it jumps
                // up to the parent folder and collapses it (ForkLift/Finder).
                if model.viewMode == .list, let it = model.selectedItems.first {
                    // 1) selected folder is open → close it
                    if model.isExpandable(it) && model.isExpanded(it) { model.toggleExpand(it); return true }
                    // 2) nested row → close its containing folder, cursor → folder
                    if let parent = model.parentRow(of: it) {
                        model.toggleExpand(parent)
                        model.select(parent)        // explicit (don't rely on repair)
                        return true
                    }
                    // 3) top-level → keep closing opened folders, walking upward
                    if let above = model.nearestExpandedAbove(of: it) {
                        model.select(above)
                        model.toggleExpand(above)
                        return true
                    }
                }
                return false
            case 124:
                if model.viewMode == .icons || model.viewMode == .gallery {
                    moveSel(by: 1, extend: shift); return true
                }
                // List: → expands the selected folder, or steps to the next row
                // when there's nothing left to open here — so mashing → opens
                // every folder and walks the whole tree.
                if model.viewMode == .list && !shift {
                    return model.expandOrAdvance()
                }
                return false
            // PgUp/PgDn move the SELECTION a viewport's worth (Explorer-style —
            // works even when there's nothing to scroll); Home/End jump it to
            // the first/last item. The views scroll to follow the selection.
            case 116: moveSel(by: -pageRows(), extend: shift); return true
            case 121: moveSel(by: pageRows(), extend: shift); return true
            case 115: moveSel(by: -model.items.count, extend: shift); return true
            case 119: moveSel(by: model.items.count, extend: shift); return true
            case 53:  // esc — shortcuts overlay → Quick Look → close the inspector
                if workspace.showWelcome { workspace.showWelcome = false; return true }
                if QLPreviewPanel.sharedPreviewPanelExists() { QLPreviewPanel.shared().orderOut(nil); return true }
                if workspace.inspectorVisible { workspace.inspectorVisible = false; return true }
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
                refreshQLPanelIfVisible()
                return true
            }
        }

        // --- Command combinations (non-bindable system set) ---
        // Everything bindable (tabs, layouts, navigation, toggles…) went
        // through the keymap dispatch at the top.
        if cmd {
            if opt {
                // Tab selection ⌘⌥1…⌘⌥9
                if let n = Int(chars), (1...9).contains(n) {
                    workspace.activePaneModel.select(n - 1); return true
                }
            }
            switch chars {
            case "?":
                // ⌘? toggles the shortcuts overlay (Esc or ⌘? again closes it).
                workspace.showWelcome.toggle(); return true
            case "z":
                // ⌘Z undo / ⌘⇧Z redo file operations. FileUndo broadcasts the
                // touched dirs, so every tab/pane showing them refreshes (not just
                // the visible active one — N-010).
                let did = shift ? FileUndo.shared.redo() : FileUndo.shared.undo()
                if !did { NSSound.beep() }
                return true
            case "=", "+": bumpScale(1); return true
            case "-": bumpScale(-1); return true
            case "c": model.copySelectionToPasteboard(); return true
            case "x": model.cutSelectionToPasteboard(); return true
            case "v": model.pasteFromPasteboard(); return true
            case "a": model.selectAll(); return true
            default: break
            }
        }
        return false
    }

    /// Execute one keymap-driven action. Always consumes the event.
    private func dispatch(_ action: KeyAction) -> Bool {
        switch action {
        case .newTab: workspace.activePaneModel.newTab()
        case .closeTab:
            // Close the current tab → pane → window (Finder/browser order).
            let pane = workspace.activePaneModel
            if pane.tabs.count > 1 { pane.closeCurrent() }
            else if workspace.layout.count > 1 { workspace.closeActivePane() }
            else { NSApp.keyWindow?.performClose(nil) }
        case .commandPalette: palette?.toggle()
        case .toggleTerminal: workspace.toggleTerminal()
        case .layoutSingle: workspace.setLayout(.single)
        case .layoutDual: workspace.setLayout(.dual)
        case .layoutRows: workspace.setLayout(.rows)
        case .layoutQuad: workspace.setLayout(.quad)
        case .viewModePrev: cycleViewMode(-1)
        case .viewModeNext: cycleViewMode(1)
        case .toggleSidebar: toggleLeftSidebar()
        case .toggleInspector: workspace.inspectorVisible.toggle()
        case .togglePathBar: workspace.pathBarVisible.toggle(); workspace.save()
        case .getInfo: model.showGetInfo()
        case .duplicate: model.duplicateSelection()
        case .toggleFavorite: workspace.toggleFavoriteCurrent()
        // Inline path editing lives in the path bar — only useful when it's
        // showing. When the bar is hidden, fall back to the modal prompt (#14).
        case .goToFolder:
            if workspace.pathBarVisible { model.beginPathEdit() } else { model.goToFolderPrompt() }
        case .newFolder: model.makeNewFolder()
        case .reload: model.reload()
        case .toggleHidden: model.showHidden.toggle()
        case .goBack: model.goBack(); refocusContent()
        case .goForward: model.goForward(); refocusContent()
        case .goUp: model.goUp(); refocusContent()
        case .openSelected: model.openSelected()
        case .copyPath: model.copyPathToPasteboard()
        case .copyFolderPath: model.copyCurrentFolderPath()
        case .transferCopy: workspace.transferToOtherPane(move: false)
        case .transferMove: workspace.transferToOtherPane(move: true)
        case .quickLook: toggleQuickLook()
        case .rename: model.beginRename()
        case .trash: model.trashSelection()
        case .openWith: openWithPresetApp()
        case .openSettings: Keymap.openSettingsFile()
        }
        return true
    }

    /// F4: open the selection in a preset app (e.g. a Markdown editor), set via
    /// "openWith" in the ⌘, settings file. Empty → open the settings file with a
    /// pointer to the key.
    private func openWithPresetApp() {
        let app = (UserDefaults.standard.string(forKey: "anf.openWithApp") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let items = model.selectedItems
        guard !items.isEmpty else { return }
        if app.isEmpty {
            let a = NSAlert()
            a.messageText = L("No “Open With” app set", "‘다른 앱으로 열기’ 앱이 설정되지 않았어요")
            a.informativeText = L("Set \"openWithApp\": \"Typora\" (an app name or path) in Settings (⌘,), then F4 opens the selection with it.",
                                  "설정(⌘,)에 \"openWithApp\": \"Typora\"(앱 이름 또는 경로)를 넣으면 F4로 선택 항목을 그 앱으로 엽니다.")
            a.runModal()
            Keymap.openSettingsFile()
            return
        }
        FileOperations.openWith(items, app: app)
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

    /// Wraps moveSelection and refreshes the QL panel when it is open, so the
    /// preview tracks the cursor as the user navigates.
    private func moveSel(by delta: Int, extend: Bool = false, rowJump: Bool = false) {
        model.moveSelection(by: delta, extend: extend, rowJump: rowJump)
        refreshQLPanelIfVisible()
    }

    private func refreshQLPanelIfVisible() {
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              let panel = QLPreviewPanel.shared(),
              panel.isVisible else { return }
        panel.reloadData()
    }

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
