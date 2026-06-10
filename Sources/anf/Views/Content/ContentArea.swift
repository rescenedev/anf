import SwiftUI

/// Routes to the active view mode and overlays empty / loading states.
struct ContentArea: View {
    @Bindable var model: BrowserModel

    var body: some View {
        ZStack {
            switch model.viewMode {
            case .icons:   IconGridView(model: model)
            case .list:    FileListView(model: model)
            case .columns: ColumnView(model: model)
            case .gallery: GalleryView(model: model)
            }

            if model.isLoading && model.allItems.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    if model.isRemote {
                        Text("원격 연결 중…").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            } else if let err = model.remoteError, model.items.isEmpty {
                RemoteErrorState(message: err) { model.reload() }
            } else if !model.isLoading && model.items.isEmpty {
                EmptyState(filtered: !model.filterText.isEmpty)
            }
        }
        // Drop files anywhere in the pane → move them into this folder (enables
        // pane-to-pane and sidebar drops).
        .dropDestination(for: URL.self) { urls, _ in
            model.acceptDrop(urls, into: model.currentURL, copy: false)
            return true
        }
        // Click on empty space clears selection (icon/gallery modes).
        .background(
            Color.clear.contentShape(Rectangle())
                .onTapGesture { model.selection.removeAll() }
                .contextMenu { BackgroundMenu(model: model) }
        )
    }
}

/// Right-click menu for empty space inside a folder.
private struct BackgroundMenu: View {
    @Bindable var model: BrowserModel
    var body: some View {
        Button("New Folder") { model.makeNewFolder() }
        Button("Open Terminal Here") { FileOperations.openInTerminal(model.currentURL) }
        Divider()
        Button("Paste") { model.pasteFromPasteboard() }
        Button("Go to Folder…") { model.goToFolderPrompt() }
        Button("Copy Path") { model.copyPathToPasteboard() }
        Divider()
        Toggle("Show Hidden Files", isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 }))
    }
}

private struct RemoteErrorState: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text("SFTP 연결 실패").font(.title3).foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button("다시 시도", action: retry)
        }
        .padding(24)
    }
}

private struct EmptyState: View {
    let filtered: Bool
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filtered ? "magnifyingglass" : "folder")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(filtered ? "No matches" : "Empty Folder")
                .font(.title3).foregroundStyle(.secondary)
        }
    }
}
