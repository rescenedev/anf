import SwiftUI

/// Arranges the visible panes for the current layout (1 / 2 columns / 2 rows / 4),
/// with draggable dividers between panes. Proportions live in the workspace
/// (`splitRatioH`/`splitRatioV`) so quad keeps its columns aligned.
struct PaneLayoutView: View {
    @Bindable var workspace: WorkspaceModel

    private let grip: CGFloat = 9

    var body: some View {
        switch workspace.layout {
        case .single:
            pane(0)
        case .dual:
            GeometryReader { geo in
                let avail = geo.size.width - grip
                HStack(spacing: 0) {
                    pane(0).frame(width: avail * workspace.splitRatioH)
                    columnHandle(totalWidth: avail)
                    pane(1)
                }
            }
        case .rows:
            GeometryReader { geo in
                let avail = geo.size.height - grip
                VStack(spacing: 0) {
                    pane(0).frame(height: avail * workspace.splitRatioV)
                    rowHandle(totalHeight: avail)
                    pane(1)
                }
            }
        case .quad:
            GeometryReader { geo in
                let availW = geo.size.width - grip
                let availH = geo.size.height - grip
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        pane(0).frame(width: availW * workspace.splitRatioH)
                        columnHandle(totalWidth: availW)
                        pane(1)
                    }
                    .frame(height: availH * workspace.splitRatioV)
                    rowHandle(totalHeight: availH)
                    HStack(spacing: 0) {
                        pane(2).frame(width: availW * workspace.splitRatioH)
                        columnHandle(totalWidth: availW)
                        pane(3)
                    }
                }
            }
        }
    }

    private func pane(_ index: Int) -> some View {
        PaneView(workspace: workspace, index: index)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func columnHandle(totalWidth: CGFloat) -> some View {
        DragDividerHandle(
            orientation: .vertical,
            read: { workspace.splitRatioH * totalWidth },
            write: { workspace.splitRatioH = WorkspaceModel.clampSplitRatio($0 / max(totalWidth, 1)) },
            onEnded: { workspace.save() }
        )
    }

    private func rowHandle(totalHeight: CGFloat) -> some View {
        DragDividerHandle(
            orientation: .horizontal,
            read: { workspace.splitRatioV * totalHeight },
            write: { workspace.splitRatioV = WorkspaceModel.clampSplitRatio($0 / max(totalHeight, 1)) },
            onEnded: { workspace.save() }
        )
    }
}
