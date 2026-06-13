import AppKit

/// The Vault time machine: a floating panel listing snapshots newest-first.
/// Selecting one shows the files that existed then but are gone now — one click
/// brings any of them back, even after the Trash was emptied.
@MainActor
final class VaultTimelinePanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private static var open: [String: VaultTimelinePanel] = [:]

    static func show(for folder: URL) {
        let key = folder.standardizedFileURL.path
        if let existing = open[key] { existing.window.makeKeyAndOrderFront(nil); return }
        let p = VaultTimelinePanel(folder: folder)
        open[key] = p
        p.window.makeKeyAndOrderFront(nil)
    }

    private let folder: URL
    private let window: NSPanel
    private var snapshots: [VaultSnapshot] = []
    private var deleted: [String] = []
    private let snapTable = NSTableView()
    private let fileTable = NSTableView()
    private let status = NSTextField(labelWithString: "")

    private init(folder: URL) {
        self.folder = folder
        let w = EscPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = L("Vault Timeline — \(folder.lastPathComponent)", "Vault 타임라인 — \(folder.lastPathComponent)")
        w.isReleasedWhenClosed = false   // we own the lifetime (avoids double-free)
        self.window = w
        super.init()
        w.center()
        w.contentView = buildContent()
        w.delegate = self
        reloadSnapshots()
    }

    private func buildContent() -> NSView {
        configure(snapTable, column: L("When", "시점"), target: #selector(snapSelected))
        configure(fileTable, column: L("Recoverable files", "복구 가능한 파일"), target: nil)

        let left = scroll(snapTable, width: 220)
        let right = scroll(fileTable, width: 320)

        let restore = NSButton(title: L("Recover Selected", "선택 복구"),
                               target: self, action: #selector(recover))
        restore.keyEquivalent = "\r"
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor

        let split = NSStackView(views: [left, right])
        split.distribution = .fillProportionally
        split.spacing = 10

        let bottom = NSStackView(views: [status, NSView(), restore])
        bottom.orientation = .horizontal
        bottom.alignment = .centerY

        let stack = NSStackView(views: [split, bottom])
        stack.orientation = .vertical
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
        return host
    }

    private func configure(_ t: NSTableView, column title: String, target: Selector?) {
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c"))
        col.title = title
        t.addTableColumn(col)
        t.headerView = NSTableHeaderView()
        t.dataSource = self
        t.delegate = self
        t.usesAlternatingRowBackgroundColors = true
        if let target { t.target = self; t.action = target }
    }

    private func scroll(_ t: NSTableView, width: CGFloat) -> NSScrollView {
        let s = NSScrollView()
        s.documentView = t
        s.hasVerticalScroller = true
        s.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true
        return s
    }

    private func reloadSnapshots() {
        let folder = self.folder
        Task { [weak self] in
            let snaps = await Task.detached { VaultService.snapshots(at: folder) }.value
            guard let self else { return }
            self.snapshots = snaps
            self.snapTable.reloadData()
            self.status.stringValue = L("\(snaps.count) snapshots", "스냅샷 \(snaps.count)개")
        }
    }

    @objc private func snapSelected() {
        let row = snapTable.selectedRow
        guard snapshots.indices.contains(row) else { deleted = []; fileTable.reloadData(); return }
        let snap = snapshots[row]
        let folder = self.folder
        Task { [weak self] in
            let gone = await Task.detached { VaultService.deletedSince(snap, at: folder) }.value
            guard let self else { return }
            self.deleted = gone
            self.fileTable.reloadData()
            self.status.stringValue = gone.isEmpty
                ? L("Nothing was deleted since this point", "이 시점 이후 삭제된 파일 없음")
                : L("\(gone.count) recoverable", "복구 가능 \(gone.count)개")
        }
    }

    @objc private func recover() {
        let srow = snapTable.selectedRow
        let frow = fileTable.selectedRow
        guard snapshots.indices.contains(srow), deleted.indices.contains(frow) else { return }
        let snap = snapshots[srow]
        let file = deleted[frow]
        let folder = self.folder
        Task { [weak self] in
            let ok = await Task.detached { VaultService.restore(file, from: snap, at: folder) }.value
            guard let self else { return }
            self.status.stringValue = ok
                ? L("Recovered \(file)", "\(file) 복구됨")
                : L("Couldn’t recover \(file)", "\(file) 복구 실패")
            if ok { self.snapSelected() }   // refresh the recoverable list
        }
    }

    // MARK: Data source / delegate

    func numberOfRows(in t: NSTableView) -> Int { t === snapTable ? snapshots.count : deleted.count }

    func tableView(_ t: NSTableView, viewFor c: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = (t.makeView(withIdentifier: id, owner: self) as? NSTableCellView) ?? {
            let v = NSTableCellView()
            let tf = NSTextField(labelWithString: "")
            tf.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(tf); v.textField = tf
            NSLayoutConstraint.activate([
                tf.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
                tf.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            ])
            v.identifier = id
            return v
        }()
        if t === snapTable {
            cell.textField?.stringValue = Self.when(snapshots[row].date)
        } else {
            cell.textField?.stringValue = deleted[row]
        }
        return cell
    }

    private static func when(_ d: Date) -> String {
        let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short
        f.doesRelativeDateFormatting = true
        return f.string(from: d)
    }
}

extension VaultTimelinePanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        VaultTimelinePanel.open.removeValue(forKey: folder.standardizedFileURL.path)
    }
}
