import SwiftUI

/// Multi-column list view (Name / Date / Size / Kind), built on the native `Table`
/// for free column resizing, sorting headers and virtualisation. Row text scales
/// with ⌘ +/- via `model.textScale`.
struct FileListView: View {
    @Bindable var model: BrowserModel

    private var nameSize: CGFloat { 13 * model.textScale }
    private var subSize: CGFloat { 12 * model.textScale }

    var body: some View {
        Table(of: FileItem.self, selection: $model.selection) {
            TableColumn("Name") { item in
                HStack(spacing: 8) {
                    IconImage(image: IconProvider.shared.icon(for: item))
                        .frame(width: 16 * model.textScale, height: 16 * model.textScale)
                    Text(item.name).lineLimit(1).font(.system(size: nameSize))
                    if item.isCloudPlaceholder {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: subSize - 1))
                            .foregroundStyle(.secondary)
                            .help("In iCloud — not downloaded")
                    }
                }
                .contextMenu { FileContextMenu(model: model, item: item) }
            }
            .width(min: 220, ideal: 360)

            TableColumn("Date Modified") { item in
                Text(Format.when(item.modified))
                    .foregroundStyle(.secondary).font(.system(size: subSize))
            }
            .width(min: 140, ideal: 180)

            TableColumn("Size") { item in
                Text(item.isBrowsableContainer ? "—" : Format.bytes(item.size))
                    .foregroundStyle(.secondary).font(.system(size: subSize))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Kind") { item in
                Text(Format.kind(item))
                    .foregroundStyle(.secondary).font(.system(size: subSize)).lineLimit(1)
            }
            .width(min: 100, ideal: 160)
        } rows: {
            ForEach(model.items) { item in
                TableRow(item)
                    .itemProvider { NSItemProvider(object: item.url as NSURL) }
            }
        }
        .contextMenu(forSelectionType: FileItem.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first, let item = model.items.first(where: { $0.id == id }) {
                model.open(item)
            }
        }
    }
}
