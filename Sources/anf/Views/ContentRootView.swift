import SwiftUI

/// The content side of the split: the pane layout (1/2/4 panes with tabs) plus the
/// optional info inspector. The sidebar is a native `NSSplitViewItem`; the toolbar
/// is a native `NSToolbar` — so this view has neither.
struct ContentRootView: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    PaneLayoutView(workspace: workspace)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    TerminalPanel(workspace: workspace, availableHeight: geo.size.height)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(.easeInOut(duration: 0.2), value: workspace.showTerminal)
                if workspace.inspectorVisible {
                    DragDividerHandle(
                        orientation: .vertical,
                        sign: -1,   // dragging left grows the inspector
                        read: { workspace.inspectorWidth },
                        write: { workspace.inspectorWidth = WorkspaceModel.clampInspectorWidth(
                            $0, available: geo.size.width) },
                        onEnded: { workspace.save() }
                    )
                    InfoInspector(workspace: workspace)
                        .frame(width: WorkspaceModel.clampInspectorWidth(
                            workspace.inspectorWidth, available: geo.size.width))
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
        }
        .animation(.easeInOut(duration: 0.2), value: workspace.inspectorVisible)
        .overlay(alignment: .bottom) { TransferHUD() }
        .overlay { WelcomeOverlay(workspace: workspace) }
        .overlay(alignment: .top) { UpdateBanner() }
        .task { UpdateChecker.shared.checkIfDue() }
    }
}

/// Dismissible "new version" pill, shown at most once per release.
private struct UpdateBanner: View {
    private var checker: UpdateChecker { UpdateChecker.shared }

    var body: some View {
        if let v = checker.availableVersion {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(.tint)
                Text(L("anf \(v) is out — ", "anf \(v) 출시 — ")).font(.system(size: 12))
                    + Text("brew upgrade --cask anf").font(.system(size: 12, design: .monospaced))
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/rescenedev/anf/releases/latest")!)
                } label: { Text(L("Release Notes", "릴리즈 노트")).font(.system(size: 12)) }
                .buttonStyle(.link)
                Button {
                    checker.dismiss()
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                }
                .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            .padding(.top, 10)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Floating progress bar for large copies — appears only while FileTransfer is
/// active; the cancel button stops between items (finished items are kept).
private struct TransferHUD: View {
    private var transfer: FileTransfer { FileTransfer.shared }
    // The bar sits at the bottom by default but can be dragged anywhere (it can
    // cover the files you're acting on) — requested on #63. The position sticks
    // for the session.
    @State private var offset: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        if transfer.isActive {
            HStack(spacing: 12) {
                ProgressView(value: transfer.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 220)
                Text(transfer.label)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(L("Cancel", "취소")) { transfer.cancel() }
                    .controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .padding(.bottom, 18)
            .offset(x: offset.width + drag.width, y: offset.height + drag.height)
            .gesture(
                DragGesture()
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        offset.width += value.translation.width
                        offset.height += value.translation.height
                    }
            )
            .help(L("Drag to move", "드래그해서 이동"))
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

