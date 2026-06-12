import AppKit

// MARK: - Panel (borderless windows must opt into key status)

/// Table that lets the palette be dragged from anywhere over the results — a
/// click still selects/activates a row, but a drag moves the whole panel.
final class PaletteTableView: NSTableView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class PalettePanel: NSPanel {
    var onResignKey: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }
}

// MARK: - Divider row ("내용 일치" section header)

final class PaletteDividerView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .tertiaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String) { label.stringValue = title }
}

// MARK: - Row view (icon + name + path)

final class PaletteRowView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let subtitle = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        icon.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingMiddle
        title.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .tertiaryLabelColor
        subtitle.lineBreakMode = .byTruncatingHead
        subtitle.alignment = .right
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        addSubview(icon); addSubview(title); addSubview(subtitle)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 20),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            title.centerYAnchor.constraint(equalTo: centerYAnchor),
            subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: title.trailingAnchor, constant: 12),
            subtitle.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitle.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }

    func configure(with t: CommandPaletteController.Target) {
        icon.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: nil)
        title.stringValue = t.name
        subtitle.stringValue = t.url.deletingLastPathComponent().path
    }
}

/// Rounded accent highlight for the selected row.
final class PaletteRowBackground: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let rect = bounds.insetBy(dx: 4, dy: 0)
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
    }
    override var isEmphasized: Bool { get { true } set {} }
}

/// Search backends for the palette's deep search. Filename matching is done via
/// the Spotlight index (`MetadataFileSearch`) + Swift fuzzy ranking; this enum
/// provides the ripgrep CONTENT search and a FileManager filename fallback used
/// when Spotlight returns nothing.
