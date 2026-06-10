import SwiftUI

/// Virtualised icon grid. `LazyVGrid` only realises visible tiles, so directories
/// with thousands of entries scroll smoothly.
struct IconGridView: View {
    @Bindable var model: BrowserModel

    private var minItem: CGFloat { model.iconSize + 28 }

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: minItem, maximum: model.iconSize + 60),
                  spacing: 10, alignment: .top)]
    }

    /// Column count SwiftUI's adaptive grid will use for a given width — fed back
    /// to the model so ↑/↓ jump a row.
    private func columnCount(for width: CGFloat) -> Int {
        let avail = width - 32   // 16pt padding each side
        return max(1, Int((avail + 10) / (minItem + 10)))
    }

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(model.items) { item in
                        tile(item)
                    }
                }
                .padding(16)
            }
            .background(.background)
            .onChange(of: geo.size.width, initial: true) {
                model.gridColumns = columnCount(for: geo.size.width)
            }
            .onChange(of: model.iconSize) {
                model.gridColumns = columnCount(for: geo.size.width)
            }
        }
    }

    @ViewBuilder
    private func tile(_ item: FileItem) -> some View {
        let base = FileTile(item: item, side: model.iconSize,
                            isSelected: model.selection.contains(item.id),
                            isEditing: model.editingItemID == item.id,
                            onCommitRename: { model.commitRename(item, to: $0) },
                            onCancelRename: { model.cancelRename() })
            .onTapGesture(count: 2) { model.open(item) }
            .onTapGesture { model.selection = [item.id] }
            .contextMenu { FileContextMenu(model: model, item: item) }
            .draggable(item.url)

        if item.isBrowsableContainer {
            base.dropDestination(for: URL.self) { urls, _ in
                model.acceptDrop(urls, into: item.url, copy: false)
                return true
            }
        } else {
            base
        }
    }
}
