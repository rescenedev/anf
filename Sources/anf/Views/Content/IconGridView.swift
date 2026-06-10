import SwiftUI

/// Virtualised icon grid. `LazyVGrid` only realises visible tiles, so directories
/// with thousands of entries scroll smoothly.
struct IconGridView: View {
    @Bindable var model: BrowserModel

    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: model.iconSize + 28, maximum: model.iconSize + 60),
                  spacing: 10, alignment: .top)]
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(model.items) { item in
                    tile(item)
                }
            }
            .padding(16)
        }
        .background(.background)
    }

    @ViewBuilder
    private func tile(_ item: FileItem) -> some View {
        let base = FileTile(item: item, side: model.iconSize,
                            isSelected: model.selection.contains(item.id))
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
