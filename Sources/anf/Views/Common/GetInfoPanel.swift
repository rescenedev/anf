import AppKit

/// Finder-style "Get Info" (⌘⌥I): a floating panel with the icon, kind, size
/// (folders sized recursively in the background), dates, POSIX permissions, the
/// full path, and editable colour tags. One panel per file; re-invoking refreshes.
@MainActor
final class GetInfoPanel: NSObject {
    private static var open: [String: GetInfoPanel] = [:]

    static func show(for item: FileItem) {
        if let existing = open[item.url.path] {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        let panel = GetInfoPanel(item: item)
        open[item.url.path] = panel
        panel.window.makeKeyAndOrderFront(nil)
    }

    private let item: FileItem
    private let window: NSPanel
    private let sizeLabel = NSTextField(labelWithString: "—")

    private init(item: FileItem) {
        self.item = item
        let w = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 460),
                        styleMask: [.titled, .closable, .utilityWindow],
                        backing: .buffered, defer: false)
        w.title = L("\(item.name) Info", "\(item.name) 정보")
        w.isFloatingPanel = true
        w.hidesOnDeactivate = false
        // This object owns the panel's lifetime; without this AppKit also
        // releases it on close (default true) → double free, like the window bug.
        w.isReleasedWhenClosed = false
        self.window = w
        super.init()
        w.center()
        w.contentView = buildContent()
        w.delegate = self
        if item.isBrowsableContainer { computeFolderSize() }
    }

    private func row(_ label: String, _ value: String) -> NSView {
        let l = NSTextField(labelWithString: label)
        l.font = .systemFont(ofSize: 11, weight: .semibold)
        l.textColor = .secondaryLabelColor
        l.alignment = .right
        l.setContentHuggingPriority(.required, for: .horizontal)
        l.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let v = NSTextField(wrappingLabelWithString: value)
        v.font = .systemFont(ofSize: 11)
        v.isSelectable = true
        let h = NSStackView(views: [l, v])
        h.alignment = .firstBaseline
        h.spacing = 8
        return h
    }

    private func buildContent() -> NSView {
        let icon = NSImageView()
        icon.image = IconProvider.shared.icon(for: item)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let name = NSTextField(wrappingLabelWithString: item.name)
        name.font = .systemFont(ofSize: 14, weight: .semibold)
        name.alignment = .center

        sizeLabel.stringValue = item.isBrowsableContainer ? L("Calculating…", "계산 중…")
                                                          : Format.bytes(item.size)
        sizeLabel.font = .systemFont(ofSize: 11)
        sizeLabel.isSelectable = true
        let sizeLab = NSTextField(labelWithString: L("Size", "크기"))
        sizeLab.font = .systemFont(ofSize: 11, weight: .semibold)
        sizeLab.textColor = .secondaryLabelColor
        sizeLab.alignment = .right
        sizeLab.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let sizeRow = NSStackView(views: [sizeLab, sizeLabel])
        sizeRow.alignment = .firstBaseline; sizeRow.spacing = 8

        var rows: [NSView] = [
            row(L("Kind", "종류"), Format.kind(item)),
            sizeRow,
            row(L("Created", "생성일"), Format.when(item.created)),
            row(L("Modified", "수정일"), Format.when(item.modified)),
            row(L("Where", "위치"), item.url.deletingLastPathComponent().path),
            row(L("Permissions", "권한"), permissions()),
        ]
        rows.append(tagsRow())

        let info = NSStackView(views: rows)
        info.orientation = .vertical
        info.alignment = .leading
        info.spacing = 9

        let stack = NSStackView(views: [icon, name, NSBox.separator(), info])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(greaterThanOrEqualTo: container.bottomAnchor, constant: -12),
        ])
        return container
    }

    private func tagsRow() -> NSView {
        let lab = NSTextField(labelWithString: L("Tags", "태그"))
        lab.font = .systemFont(ofSize: 11, weight: .semibold)
        lab.textColor = .secondaryLabelColor
        lab.alignment = .right
        lab.widthAnchor.constraint(equalToConstant: 84).isActive = true

        let current = Set(FileTags.tags(of: item.url))
        let dots = NSStackView()
        dots.spacing = 6
        for (name, color) in FileTags.standard {
            let b = NSButton()
            b.bezelStyle = .circular
            b.isBordered = false
            b.title = ""
            b.image = swatch(color, filled: current.contains(name))
            b.toolTip = name
            b.target = self
            b.action = #selector(toggleTag(_:))
            b.identifier = NSUserInterfaceItemIdentifier(name)
            dots.addArrangedSubview(b)
        }
        let h = NSStackView(views: [lab, dots])
        h.alignment = .centerY; h.spacing = 8
        return h
    }

    private func swatch(_ color: NSColor, filled: Bool) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let img = NSImage(size: size)
        img.lockFocus()
        let rect = NSRect(x: 1, y: 1, width: 14, height: 14)
        let path = NSBezierPath(ovalIn: rect)
        if filled { color.setFill(); path.fill() }
        else { color.setStroke(); path.lineWidth = 1.5; path.stroke() }
        img.unlockFocus()
        return img
    }

    @objc private func toggleTag(_ sender: NSButton) {
        guard let name = sender.identifier?.rawValue else { return }
        FileTags.toggle(name, on: item.url)
        let now = Set(FileTags.tags(of: item.url))
        sender.image = swatch(FileTags.color(for: name) ?? .gray, filled: now.contains(name))
    }

    private func permissions() -> String {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: item.url.path),
              let perm = attrs[.posixPermissions] as? Int else { return "—" }
        func rwx(_ b: Int) -> String {
            "\(b & 4 != 0 ? "r" : "-")\(b & 2 != 0 ? "w" : "-")\(b & 1 != 0 ? "x" : "-")"
        }
        return "\(rwx((perm >> 6) & 7))\(rwx((perm >> 3) & 7))\(rwx(perm & 7))  (\(String(perm, radix: 8)))"
    }

    private func computeFolderSize() {
        let url = item.url
        Task { [weak self] in
            let bytes = await FileSystemService().directorySize(of: url)
            self?.sizeLabel.stringValue = Format.bytes(bytes)
        }
    }
}

extension GetInfoPanel: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        GetInfoPanel.open.removeValue(forKey: item.url.path)
    }
}

private extension NSBox {
    static func separator() -> NSBox {
        let b = NSBox(); b.boxType = .separator
        b.widthAnchor.constraint(equalToConstant: 240).isActive = true
        return b
    }
}
