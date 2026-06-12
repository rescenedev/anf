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
            row(L("Kind", "종류"), Format.kind(item))
            if item.isBrowsableContainer {
                folderSizeRow
            } else {
                row(L("Size", "크기"), Format.bytes(item.size))
            }
            row(L("Modified", "수정일"), Format.when(item.modified))
            row(L("Created", "생성일"), Format.when(item.created))
            row(L("Where", "위치"), item.url.deletingLastPathComponent().path)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(item.id)
    }

    @ViewBuilder private var folderSizeRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(L("Size", "크기")).foregroundStyle(.secondary).frame(width: 64, alignment: .trailing)
            if let folderSize {
                Text(Format.bytes(folderSize)).textSelection(.enabled)
            } else if calculating {
                ProgressView().controlSize(.small)
            } else {
                Button(L("Calculate", "계산")) {
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

/// Inspector preview for a remote (SFTP) selection — Quick Look can't read a
/// `sftp://` URL, so show the icon, name and a hint to open/download.
private struct RemotePreviewPlaceholder: View {
    let item: FileItem
    var body: some View {
        VStack(spacing: 12) {
            IconImage(image: IconProvider.shared.icon(for: item))
                .frame(width: 64, height: 64)
            Text(item.name).font(.system(size: 13, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.center)
            if !item.isDirectory {
                Text(Format.bytes(item.size)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(L("Opens after download (Return or double-click)", "열기(↵ 또는 더블클릭) 시 다운로드 후 표시됩니다"))
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Instant placeholder for opaque binaries (.so / .dylib / unix executables):
/// Quick Look would grind through megabytes just to draw a "?" page, which
/// stalled arrowing past them with the inspector open.
private struct BinaryPreviewPlaceholder: View {
    let item: FileItem
    var body: some View {
        VStack(spacing: 12) {
            IconImage(image: IconProvider.shared.icon(for: item))
                .frame(width: 64, height: 64)
            Text(item.name).font(.system(size: 13, weight: .medium))
                .lineLimit(2).multilineTextAlignment(.center)
            Text("\(Format.bytes(item.size)) · \(Format.kind(item))")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Text(L("No preview for this format", "미리보기를 제공하지 않는 형식입니다"))
                .font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Fallback for types nothing else claimed: sniff the head of the file — real
/// text renders in the text preview, anything binary skips Quick Look entirely
/// and shows the instant placeholder.
private struct SniffedPreview: View {
    let item: FileItem
    let fontSize: CGFloat
    @State private var binary: Bool?

    var body: some View {
        Group {
            switch binary {
            case .some(true): BinaryPreviewPlaceholder(item: item)
            case .some(false): TextFilePreview(url: item.url, fontSize: fontSize)
            case .none: Color.clear   // sniffing takes ~a syscall; no spinner needed
            }
        }
        .task(id: item.url) {
            let url = item.url
            binary = await Task.detached(priority: .userInitiated) {
                FileItem.looksBinary(url)
            }.value
        }
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
                    if target.url.scheme == "sftp" {
                        RemotePreviewPlaceholder(item: target)
                    } else if target.isOpaqueBinary {
                        BinaryPreviewPlaceholder(item: target)
                    } else if target.ext == "docx" || target.ext == "hwpx" {
                        // Native structured render (headings/tables/lists/bold;
                        // hwpx collects only hp:t body runs, so form-field
                        // metadata junk never reaches the preview) — instant
                        // and full-width, no Quick Look page image.
                        DocxPreview(url: target.url, fontSize: workspace.previewTextSize)
                    } else if target.isExtractableDocument {
                        // pptx/xlsx: extracted text (slides/sheets read fine).
                        DocumentTextPreview(url: target.url, fontSize: workspace.previewTextSize)
                    } else if target.isMarkdown {
                        MarkdownPreview(url: target.url, fontSize: workspace.previewTextSize)
                    } else if target.isJSON {
                        JSONPreview(url: target.url, fontSize: workspace.previewTextSize)
                    } else if target.isPlainTextLike {
                        TextFilePreview(url: target.url, fontSize: workspace.previewTextSize)
                    } else if target.isQuickLookFriendly {
                        QuickLookView(url: target.url)
                    } else {
                        // Unknown type: sniff the content — text shows as text,
                        // binary skips QL entirely (instant placeholder).
                        SniffedPreview(item: target, fontSize: workspace.previewTextSize)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id("\(target.url.path)|\(target.isCloudPlaceholder)")
                if target.isCloudPlaceholder {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(L("Downloading from iCloud…", "iCloud에서 다운로드 중…"))
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
                    Text(L("Select an item", "항목을 선택하세요")).foregroundStyle(.secondary)
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
                .help(showDetails ? L("Hide Info", "정보 가리기") : L("Show Info", "정보 보기"))
            }
        }
        .onChange(of: target?.id, initial: true) {
            if let target { model.downloadFromCloud(target) }
        }
    }
}
