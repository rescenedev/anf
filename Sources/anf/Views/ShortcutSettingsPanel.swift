import AppKit

/// Floating panel that lets users view and rebind every customisable shortcut.
/// Presented via `ShortcutSettingsPanel.show()`.
@MainActor
final class ShortcutSettingsPanel: NSObject, NSWindowDelegate,
                                   NSTableViewDataSource, NSTableViewDelegate {
    static let shared = ShortcutSettingsPanel()

    private var panel: NSPanel?
    private var table: NSTableView!
    private var actions: [ShortcutAction] = ShortcutAction.allCases
    private var recordingRow: Int? = nil       // index currently awaiting a key press
    private var monitor: Any? = nil            // local event monitor while recording

    // MARK: - Public API

    func show() {
        if let existing = panel {
            existing.makeKeyAndOrderFront(nil)
            return
        }
        panel = makePanel()
        panel?.delegate = self
        panel?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Panel construction

    private func makePanel() -> NSPanel {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        p.title = L("Keyboard Shortcuts", "단축키 설정")
        p.isReleasedWhenClosed = false
        p.center()

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 44, width: 500, height: 436))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false

        let tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true
        tv.rowHeight = 24
        tv.focusRingType = .none

        let actionCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionCol.title = L("Action", "동작")
        actionCol.minWidth = 200
        actionCol.width = 300
        tv.addTableColumn(actionCol)

        let shortcutCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("shortcut"))
        shortcutCol.title = L("Shortcut", "단축키")
        shortcutCol.minWidth = 100
        shortcutCol.width = 160
        tv.addTableColumn(shortcutCol)

        tv.dataSource = self
        tv.delegate = self
        table = tv

        scroll.documentView = tv
        tv.frame = scroll.bounds
        tv.autoresizingMask = [.width]

        // Reset All button
        let resetAll = NSButton(
            title: L("Reset All", "모두 초기화"),
            target: self,
            action: #selector(resetAllClicked)
        )
        resetAll.bezelStyle = .rounded
        resetAll.autoresizingMask = [.minXMargin]
        resetAll.sizeToFit()
        resetAll.frame.origin = NSPoint(x: 12, y: 10)

        // Hint label
        let hint = NSTextField(labelWithString:
            L("Click a shortcut to record a new one · ESC to cancel",
              "단축키를 클릭하면 새 단축키를 녹화합니다 · ESC로 취소"))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.autoresizingMask = [.minXMargin, .maxXMargin]
        hint.sizeToFit()
        hint.frame.origin = NSPoint(
            x: (500 - hint.frame.width) / 2,
            y: 14)

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 480))
        container.autoresizingMask = [.width, .height]
        container.addSubview(scroll)
        container.addSubview(resetAll)
        container.addSubview(hint)
        p.contentView = container
        return p
    }

    // MARK: - NSTableViewDataSource

    func numberOfRows(in tableView: NSTableView) -> Int { actions.count }

    // MARK: - NSTableViewDelegate

    func tableView(_ tableView: NSTableView,
                   viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let action = actions[row]
        let id = tableColumn?.identifier.rawValue ?? ""

        if id == "action" {
            let cell = NSTextField(labelWithString: action.displayName)
            cell.font = .systemFont(ofSize: 13)
            return cell
        }

        if id == "shortcut" {
            let isRecording = recordingRow == row
            let label: String
            if isRecording {
                label = L("Press keys…", "키를 누르세요…")
            } else {
                let binding = ShortcutStore.shared.binding(for: action)
                label = binding.displayString
            }

            let btn = NSButton(title: label, target: self, action: #selector(shortcutCellClicked(_:)))
            btn.bezelStyle = .rounded
            btn.tag = row
            btn.font = isRecording
                ? NSFont.systemFont(ofSize: 12, weight: .medium)
                : NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
            if isRecording {
                btn.contentTintColor = .controlAccentColor
            }
            btn.isBordered = true

            let resetBtn = NSButton(title: "↺", target: self, action: #selector(resetRowClicked(_:)))
            resetBtn.bezelStyle = .inline
            resetBtn.tag = row
            resetBtn.isHidden = !ShortcutStore.shared.isCustomised(action)
            resetBtn.toolTip = L("Reset to default", "기본값으로 초기화")

            let stack = NSStackView(views: [btn, resetBtn])
            stack.orientation = .horizontal
            stack.spacing = 4
            stack.alignment = .centerY
            stack.distribution = .fill
            return stack
        }
        return nil
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    // MARK: - Actions

    @objc private func shortcutCellClicked(_ sender: NSButton) {
        let row = sender.tag
        if recordingRow == row {
            stopRecording()
            return
        }
        startRecording(row: row)
    }

    @objc private func resetRowClicked(_ sender: NSButton) {
        let row = sender.tag
        ShortcutStore.shared.reset(actions[row])
        table.reloadData(forRowIndexes: IndexSet(integer: row),
                         columnIndexes: IndexSet(0..<table.tableColumns.count))
    }

    @objc private func resetAllClicked() {
        ShortcutStore.shared.resetAll()
        table.reloadData()
    }

    // MARK: - Recording

    private func startRecording(row: Int) {
        stopRecording()
        recordingRow = row
        table.reloadData(forRowIndexes: IndexSet(integer: row),
                         columnIndexes: IndexSet(0..<table.tableColumns.count))

        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleRecordingEvent(event, row: row)
            return nil   // consume — don't let the app act on it while recording
        }
    }

    private func stopRecording() {
        guard let row = recordingRow else { return }
        recordingRow = nil
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        table.reloadData(forRowIndexes: IndexSet(integer: row),
                         columnIndexes: IndexSet(0..<table.tableColumns.count))
    }

    private func handleRecordingEvent(_ event: NSEvent, row: Int) {
        // ESC cancels without saving
        if event.keyCode == 53 { stopRecording(); return }

        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.function)   // strip the synthetic .function bit on Fn-combos

        // Require at least one modifier to avoid eating plain typing
        guard flags.rawValue != 0 else { stopRecording(); return }

        let binding = KeyBinding(keyCode: event.keyCode, modifiers: flags.rawValue)
        ShortcutStore.shared.set(binding, for: actions[row])
        stopRecording()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        stopRecording()
        panel = nil
    }
}
