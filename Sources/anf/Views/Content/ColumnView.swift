import SwiftUI

/// Miller columns. Each ancestor on the path gets a column; selecting a folder
/// pushes a new column by navigating, selecting a file shows it in the preview column.
struct ColumnView: View {
    @Bindable var model: BrowserModel
    var onFocus: () -> Void = {}

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                HStack(spacing: 0) {
                    // id by position, not URL: a column's identity is its depth, so
                    // a repeated path component (/a/work/work) or any URL collision
                    // can't merge columns (same fragile class as N-004's path bar).
                    ForEach(Array(model.pathComponents.enumerated()), id: \.offset) { idx, dir in
                        let childURL = idx + 1 < model.pathComponents.count
                            ? model.pathComponents[idx + 1] : nil
                        ColumnList(
                            model: model,
                            directory: dir,
                            highlightedChild: childURL,
                            onFocus: onFocus
                        )
                            .frame(width: 240)
                            .id(dir)
                        Divider()
                    }

                    if let file = model.selectedItems.first, !file.isBrowsableContainer {
                        ColumnPreview(item: file)
                            .frame(width: 300)
                            .id("preview")
                    }
                }
            }
            .onChange(of: model.currentURL) { _, _ in
                withAnimation { proxy.scrollTo(model.currentURL, anchor: .trailing) }
            }
        }
        .background(.background)
    }
}

private struct ColumnList: View {
    @Bindable var model: BrowserModel
    let directory: URL
    let highlightedChild: URL?
    let onFocus: () -> Void

    @State private var items: [FileItem] = []
    private let fs = FileSystemService()

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 1) {
                ForEach(items) { item in
                    ColumnRow(
                        item: item,
                        isSelected: highlightedChild == item.url
                            || model.selection.contains(item.id)
                    )
                    .onTapGesture {
                        onFocus()
                        if item.isBrowsableContainer {
                            model.navigate(to: item.url)
                        } else {
                            model.selection = [item.id]
                        }
                    }
                    .onTapGesture(count: 2) { model.open(item) }
                    .contextMenu { FileContextMenu(model: model, item: item) }
                }
            }
            .padding(.vertical, 4)
        }
        .task(id: directory) {
            // contentsFast = getattrlistbulk (no per-item stat) — the slow
            // resourceValues path took 1s+ for a 26k-entry column.
            items = fs.sorted(await fs.contentsFast(of: directory, showHidden: model.showHidden),
                              by: model.sort)
        }
    }
}

private struct ColumnRow: View {
    let item: FileItem
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 7) {
            IconImage(image: IconProvider.shared.icon(for: item))
                .frame(width: 16, height: 16)
            Text(item.name).lineLimit(1).font(.system(size: 13))
            Spacer(minLength: 0)
            if let tag = FileTags.primaryColor(of: item.url) {
                Circle().fill(Color(nsColor: tag)).frame(width: 8, height: 8)
            }
            if item.isBrowsableContainer {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(isSelected ? .white : .secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(isSelected ? .white : .primary)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : .clear)
        )
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }
}

private struct ColumnPreview: View {
    let item: FileItem
    var body: some View {
        VStack(spacing: 12) {
            QuickLookView(url: item.url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            InfoSummary(item: item)
        }
        .padding(14)
    }
}
