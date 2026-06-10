import SwiftUI

/// Compact metadata block reused by the column preview and the inspector.
struct InfoSummary: View {
    let item: FileItem
    @State private var folderSize: Int64?
    @State private var calculating = false
    private let fs = FileSystemService()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).font(.headline).lineLimit(2)
            row("Kind", Format.kind(item))
            if item.isBrowsableContainer {
                folderSizeRow
            } else {
                row("Size", Format.bytes(item.size))
            }
            row("Modified", Format.when(item.modified))
            row("Created", Format.when(item.created))
            row("Where", item.url.deletingLastPathComponent().path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(item.id)
    }

    @ViewBuilder private var folderSizeRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Size").foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            if let folderSize {
                Text(Format.bytes(folderSize)).textSelection(.enabled)
            } else if calculating {
                ProgressView().controlSize(.small)
            } else {
                Button("Calculate") {
                    calculating = true
                    Task {
                        let size = await fs.directorySize(of: item.url)
                        folderSize = size; calculating = false
                    }
                }
                .buttonStyle(.link).font(.system(size: 11))
            }
        }
        .font(.system(size: 11))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(k).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            Text(v).textSelection(.enabled).lineLimit(3)
        }
        .font(.system(size: 11))
    }
}

/// Right-hand inspector: a full-bleed preview of the selection. The metadata
/// block stays hidden until the ⓘ button toggles it in.
struct InfoInspector: View {
    @Bindable var workspace: WorkspaceModel
    @State private var showDetails = false

    private var model: BrowserModel { workspace.active }
    private var target: FileItem? { model.selectedItems.first }

    var body: some View {
        VStack(spacing: 0) {
            if let target {
                // `.id` includes the placeholder flag: when the iCloud download
                // lands the item flips to local and the preview re-renders with
                // the actual content instead of the generic icon.
                // Plain-text-ish files use our own preview — Quick Look renders
                // them at an unreadably small fixed size.
                Group {
                    if target.isPlainTextLike {
                        TextFilePreview(url: target.url, fontSize: workspace.previewTextSize)
                    } else {
                        QuickLookView(url: target.url)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("\(target.url.path)|\(target.isCloudPlaceholder)")
                if target.isCloudPlaceholder {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Downloading from iCloud…")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }
                if showDetails {
                    Divider()
                    InfoSummary(item: target)
                        .padding(16)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            } else {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "sidebar.right").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("Select an item").foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .frame(minWidth: 260, idealWidth: 300)
        .background(.regularMaterial)
        .overlay(alignment: .bottom) {
            if target != nil {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { showDetails.toggle() }
                } label: {
                    Image(systemName: showDetails ? "chevron.down" : "chevron.up")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(7)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.bottom, 10)
                .help(showDetails ? "Hide Info" : "Show Info")
            }
        }
        .onChange(of: target?.id, initial: true) {
            if let target { model.downloadFromCloud(target) }
        }
    }
}
