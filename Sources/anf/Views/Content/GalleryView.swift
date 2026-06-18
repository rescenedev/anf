import AppKit
import SwiftUI

/// Gallery: one large Quick Look preview with a thumbnail filmstrip below.
/// The filmstrip is a native horizontal `NSCollectionView` (view recycling,
/// native selection); the big preview stays SwiftUI/QuickLook.
struct GalleryView: View {
    @Bindable var model: BrowserModel
    var onFocus: () -> Void = {}

    private var focused: FileItem? {
        model.selectedItems.first ?? model.items.first
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Rectangle().fill(.black.opacity(0.04))
                if let focused {
                    QuickLookView(url: focused.url)
                        .padding(24)
                } else {
                    ContentUnavailableLabel(L("No Items", "항목 없음"), symbol: "photo.on.rectangle")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            FilmstripView(model: model, onFocus: onFocus)
                .frame(height: 112)
                .background(.regularMaterial)
        }
        .background(.background)
        .contentShape(Rectangle())
        .simultaneousGesture(TapGesture().onEnded(onFocus))
    }
}

/// Small helper so the gallery has a graceful empty state.
private struct ContentUnavailableLabel: View {
    let text: String
    let symbol: String
    init(_ text: String, symbol: String) { self.text = text; self.symbol = symbol }
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 42)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary)
        }
    }
}

/// Horizontal thumbnail strip — native collection view.
private struct FilmstripView: NSViewRepresentable {
    @Bindable var model: BrowserModel
    var onFocus: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(model: model, onFocus: onFocus) }

    func makeNSView(context: Context) -> NSScrollView {
        let coord = context.coordinator

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.sectionInset = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        layout.minimumInteritemSpacing = 10
        layout.minimumLineSpacing = 10
        layout.itemSize = NSSize(width: 78, height: 84)

        let cv = FilmstripCollectionView()
        cv.coordinator = coord
        cv.collectionViewLayout = layout
        cv.isSelectable = true
        cv.allowsMultipleSelection = false
        cv.allowsEmptySelection = true
        cv.backgroundColors = [.clear]
        cv.dataSource = coord
        cv.delegate = coord
        cv.register(FilmstripItem.self, forItemWithIdentifier: FilmstripItem.reuseID)
        coord.collection = cv

        let scroll = NSScrollView()
        scroll.documentView = cv
        scroll.hasHorizontalScroller = true
        scroll.hasVerticalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.model = model
        context.coordinator.onFocus = onFocus
        context.coordinator.sync()
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var model: BrowserModel
        var onFocus: () -> Void
        weak var collection: NSCollectionView?
        private var lastVersion = -1
        private var lastModelID: BrowserModel.ID?
        private var lastFocusedID: FileItem.ID?
        private var syncing = false

        init(model: BrowserModel, onFocus: @escaping () -> Void) {
            self.model = model
            self.onFocus = onFocus
        }

        var items: [FileItem] { model.items }

        func focusPaneFromMouse() {
            onFocus()
        }
        private var focusedID: FileItem.ID? {
            model.selectedItems.first?.id ?? model.items.first?.id
        }

        func sync() {
            guard let cv = collection else { return }
            // Tab switch reuses this coordinator with the next tab's model; its
            // per-model itemsVersion can collide with the previous tab's last
            // value, so force a reload to avoid showing the old tab's gallery.
            if lastModelID != model.id {
                lastModelID = model.id
                lastVersion = -1
                lastFocusedID = nil
            }
            if lastVersion != model.itemsVersion {
                lastVersion = model.itemsVersion
                cv.reloadData()
                lastFocusedID = nil
            }
            guard lastFocusedID != focusedID else { return }
            lastFocusedID = focusedID
            guard let id = focusedID,
                  let row = items.firstIndex(where: { $0.id == id }) else { return }
            let path = IndexPath(item: row, section: 0)
            syncing = true
            cv.deselectItems(at: cv.selectionIndexPaths)
            cv.selectItems(at: [path], scrollPosition: .centeredHorizontally)
            syncing = false
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

        func collectionView(_ collectionView: NSCollectionView,
                            numberOfItemsInSection section: Int) -> Int { items.count }

        func collectionView(_ collectionView: NSCollectionView,
                            itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
            let cell = collectionView.makeItem(withIdentifier: FilmstripItem.reuseID,
                                               for: indexPath) as! FilmstripItem
            if indexPath.item < items.count {
                let item = items[indexPath.item]
                cell.configure(with: item)
                cell.onDoubleClick = { [weak self] in self?.model.open(item) }
            }
            return cell
        }

        func collectionView(_ collectionView: NSCollectionView,
                            didSelectItemsAt indexPaths: Set<IndexPath>) {
            guard !syncing, let path = indexPaths.first, path.item < items.count else { return }
            let id = items[path.item].id
            lastFocusedID = id
            model.selection = [id]
        }
    }
}

private final class FilmstripCollectionView: NSCollectionView {
    weak var coordinator: FilmstripView.Coordinator?

    override func mouseDown(with event: NSEvent) {
        coordinator?.focusPaneFromMouse()
        super.mouseDown(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        coordinator?.focusPaneFromMouse()
        super.rightMouseDown(with: event)
    }
}

/// One filmstrip cell: thumbnail with an accent border when focused, name below.
private final class FilmstripItem: NSCollectionViewItem {
    static let reuseID = NSUserInterfaceItemIdentifier("anf.filmstrip.item")

    private let thumb = NSImageView()
    private let name = NSTextField(labelWithString: "")
    private var currentID: FileItem.ID?
    var onDoubleClick: (() -> Void)?

    override func loadView() {
        view = FilmstripClickView { [weak self] in self?.onDoubleClick?() }

        thumb.translatesAutoresizingMaskIntoConstraints = false
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true
        thumb.layer?.cornerRadius = 6
        thumb.layer?.cornerCurve = .continuous
        thumb.layer?.masksToBounds = true
        thumb.layer?.borderColor = NSColor.controlAccentColor.cgColor

        name.translatesAutoresizingMaskIntoConstraints = false
        name.font = .systemFont(ofSize: 10)
        name.alignment = .center
        name.lineBreakMode = .byTruncatingMiddle

        view.addSubview(thumb)
        view.addSubview(name)
        NSLayoutConstraint.activate([
            thumb.topAnchor.constraint(equalTo: view.topAnchor),
            thumb.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 72),
            thumb.heightAnchor.constraint(equalToConstant: 60),
            name.topAnchor.constraint(equalTo: thumb.bottomAnchor, constant: 4),
            name.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            name.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
    }

    func configure(with item: FileItem) {
        currentID = item.id
        name.stringValue = item.name
        thumb.image = ThumbnailProvider.shared.cached(for: item, side: 144)
            ?? IconProvider.shared.icon(for: item)
        if item.supportsThumbnail,
           ThumbnailProvider.shared.cached(for: item, side: 144) == nil {
            let id = item.id
            Task { [weak self] in
                guard let image = await ThumbnailProvider.shared.thumbnail(for: item, side: 144),
                      let self, self.currentID == id else { return }
                self.thumb.image = image
            }
        }
        applySelectionStyle()
    }

    override var isSelected: Bool {
        didSet { applySelectionStyle() }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        currentID = nil
    }

    private func applySelectionStyle() {
        thumb.layer?.borderWidth = isSelected ? 3 : 0
        name.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }
}

private final class FilmstripClickView: NSView {
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
