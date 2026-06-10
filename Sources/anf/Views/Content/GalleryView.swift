import SwiftUI

/// Gallery: one large Quick Look preview with a thumbnail filmstrip below.
/// Arrow keys / clicks move the focused item.
struct GalleryView: View {
    @Bindable var model: BrowserModel

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
                    ContentUnavailableLabel("No items", symbol: "photo.on.rectangle")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()

            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        ForEach(model.items) { item in
                            GalleryThumb(item: item,
                                         isSelected: focused?.id == item.id)
                                .id(item.id)
                                .onTapGesture { model.selection = [item.id] }
                                .onTapGesture(count: 2) { model.open(item) }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .frame(height: 112)
                .background(.regularMaterial)
                .onChange(of: model.selection) { _, _ in
                    if let id = focused?.id {
                        withAnimation { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
        .background(.background)
    }
}

private struct GalleryThumb: View {
    let item: FileItem
    let isSelected: Bool
    @State private var thumb: NSImage?

    var body: some View {
        VStack(spacing: 4) {
            Group {
                if let thumb {
                    IconImage(image: thumb)
                } else {
                    IconImage(image: IconProvider.shared.icon(for: item))
                        .padding(8)
                }
            }
            .frame(width: 72, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
            )
            Text(item.name).font(.system(size: 10)).lineLimit(1)
                .frame(width: 78)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .task(id: item.id) {
            thumb = await ThumbnailProvider.shared.thumbnail(for: item, side: 144)
        }
    }
}

/// Small helper so the gallery has a graceful empty state on macOS 14.
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
