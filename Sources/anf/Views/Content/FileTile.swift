import SwiftUI

/// One icon-grid cell: a Quick Look thumbnail (falling back to the system icon)
/// plus an editable name label. Thumbnails load lazily per appearance.
struct FileTile: View {
    let item: FileItem
    let side: CGFloat
    let isSelected: Bool
    var isEditing: Bool = false
    var onCommitRename: (String) -> Void = { _ in }
    var onCancelRename: () -> Void = {}

    @State private var thumb: NSImage?

    private var glyphSide: CGFloat { side }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                if let thumb {
                    IconImage(image: thumb)
                        .frame(width: glyphSide, height: glyphSide)
                        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
                        .transition(.opacity)
                } else {
                    IconImage(image: IconProvider.shared.icon(for: item))
                        .frame(width: glyphSide * 0.86, height: glyphSide * 0.86)
                }
            }
            .frame(width: glyphSide, height: glyphSide)

            if isEditing {
                InlineRenameField(
                    initialName: item.name, isDirectory: item.isDirectory, fontSize: 12,
                    onCommit: onCommitRename, onCancel: onCancelRename)
                    .frame(width: side + 24, height: 22)
            } else {
                HStack(spacing: 3) {
                    Text(item.name)
                    if item.isCloudPlaceholder {
                        Image(systemName: "icloud.and.arrow.down")
                            .font(.system(size: 10))
                            .foregroundStyle(isSelected ? .white : .secondary)
                    }
                }
                    .font(.system(size: 12))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isSelected ? .white : .primary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isSelected ? Color.accentColor : .clear)
                    )
                    .frame(maxWidth: side + 24)
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : .clear)
        )
        .contentShape(Rectangle())
        .task(id: item.id) {
            thumb = ThumbnailProvider.shared.cached(for: item, side: side * 2)
            if thumb == nil, item.supportsThumbnail {
                let generated = await ThumbnailProvider.shared.thumbnail(for: item, side: side * 2)
                withAnimation(.easeOut(duration: 0.18)) { thumb = generated }
            }
        }
    }
}
