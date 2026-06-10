import SwiftUI

/// The content side of the split: the pane layout (1/2/4 panes with tabs) plus the
/// optional info inspector. The sidebar is a native `NSSplitViewItem`; the toolbar
/// is a native `NSToolbar` — so this view has neither.
struct ContentRootView: View {
    @Bindable var workspace: WorkspaceModel

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                PaneLayoutView(workspace: workspace)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .overlay {
            if workspace.paletteVisible {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.12).ignoresSafeArea()
                        .onTapGesture { workspace.paletteVisible = false }
                    QuickJumpView(workspace: workspace).padding(.top, 90)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: workspace.paletteVisible)
    }
}

