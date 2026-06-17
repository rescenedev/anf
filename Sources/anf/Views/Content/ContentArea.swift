import SwiftUI

/// Routes to the active view mode and overlays empty / loading states.
struct ContentArea: View {
    @Bindable var model: BrowserModel
    /// Whether this pane is the focused one (#59). Single-pane → always true.
    var paneActive: Bool = true

    var body: some View {
        ZStack {
            // True window translucency: the desktop shows through, blurred. A faint
            // gradient tint on top keeps text readable without killing the effect.
            VisualEffectView(material: .underWindowBackground, blending: .behindWindow)
                .overlay(
                    LinearGradient(
                        colors: [Color(nsColor: .windowBackgroundColor).opacity(0.55),
                                 Color(nsColor: .windowBackgroundColor).opacity(0.42)],
                        startPoint: .top, endPoint: .bottom))
                .ignoresSafeArea()

            switch model.viewMode {
            case .icons:   IconGridView(model: model)
            case .list:    FileListView(model: model, paneActive: paneActive)
            case .columns: ColumnView(model: model)
            case .gallery: GalleryView(model: model)
            }

            if model.networkStalled {
                // The volume blipped — the (possibly stale) listing stays visible
                // behind this card, which refreshes itself when the mount returns.
                NetworkStalledState { model.reload() }
            } else if model.isLoading && model.allItems.isEmpty {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large)
                    if model.isRemote {
                        Text(L("Connecting…", "원격 연결 중…")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
            } else if let err = model.remoteError, model.items.isEmpty {
                RemoteErrorState(message: err) { model.reload() }
            } else if !model.isLoading && model.items.isEmpty {
                if model.accessDenied {
                    VStack(spacing: 10) {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 44)).foregroundStyle(.tertiary)
                        Text(L("You don’t have permission to read this folder", "이 폴더를 읽을 권한이 없습니다"))
                            .font(.title3).foregroundStyle(.secondary)
                        Text(L("Allow anf access in System Settings → Privacy & Security.", "시스템 설정 > 개인정보 보호 및 보안에서 anf의 접근을 허용해 보세요."))
                            .font(.system(size: 12)).foregroundStyle(.tertiary)
                    }
                } else {
                    EmptyState(filtered: !model.filterText.isEmpty)
                }
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
        Button(L("New Folder", "새 폴더")) { model.makeNewFolder() }
        Button(L("Open Terminal Here", "여기서 터미널 열기")) { FileOperations.openInTerminal(model.currentURL) }
        Divider()
        Button(L("Paste", "붙여넣기")) { model.pasteFromPasteboard() }
        Button(L("Go to Folder…", "폴더로 이동…")) { model.goToFolderPrompt() }
        Button(L("Copy Path", "경로 복사")) { model.copyPathToPasteboard() }
        Divider()
        Toggle(L("Show Hidden Files", "숨김 파일 보기"), isOn: Binding(get: { model.showHidden }, set: { model.showHidden = $0 }))
    }
}

private struct RemoteErrorState: View {
    let message: String
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(L("SFTP Connection Failed", "SFTP 연결 실패")).font(.title3).foregroundStyle(.secondary)
            Text(message)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button(L("Retry", "다시 시도"), action: retry)
        }
        .padding(24)
    }
}

/// Shown when a (network) volume went unreachable mid-session. The last listing
/// stays visible behind it; anf retries on its own, so this is reassurance, not
/// an error the user has to act on.
private struct NetworkStalledState: View {
    let retry: () -> Void
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 40)).foregroundStyle(.tertiary)
            Text(L("Reconnecting to the network drive…", "네트워크 드라이브에 다시 연결 중…"))
                .font(.title3).foregroundStyle(.secondary)
            Text(L("Showing the last view — this refreshes automatically when the drive is back.",
                   "마지막 화면을 표시 중입니다 — 드라이브가 돌아오면 자동으로 새로고침됩니다."))
                .font(.system(size: 12)).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).frame(maxWidth: 360)
            Button(L("Retry Now", "지금 다시 시도"), action: retry)
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

private struct EmptyState: View {
    let filtered: Bool
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: filtered ? "magnifyingglass" : "folder")
                .font(.system(size: 44)).foregroundStyle(.tertiary)
            Text(filtered ? L("No Matches", "일치하는 항목 없음") : L("Empty Folder", "빈 폴더"))
                .font(.title3).foregroundStyle(.secondary)
        }
    }
}
