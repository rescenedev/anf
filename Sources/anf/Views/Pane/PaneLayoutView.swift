import SwiftUI

/// Arranges the visible panes for the current layout (1 / 2 columns / 2 rows / 4),
/// with draggable dividers between panes. Proportions live in the workspace
/// (`splitRatioH`/`splitRatioV`) so quad keeps its columns aligned.
///
/// Panes are positioned by absolute frame inside ONE stable `ZStack` (not a
/// `switch` that returns a different view tree per layout). A `switch` makes
/// SwiftUI tear down and rebuild every pane's NSTableView on each ⌘1–4 — and
/// rebuilding a 26k-row listing is what made layout switching feel slow. Here
/// each pane keeps a stable identity (its index), so a pane that stays visible
/// across a layout change is reused, not recreated; only genuinely newly-revealed
/// or hidden panes mount/unmount.
struct PaneLayoutView: View {
    @Bindable var workspace: WorkspaceModel

    private let grip: CGFloat = 9

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(0..<4, id: \.self) { i in
                    if let r = rect(for: i, in: geo.size) {
                        pane(i)
                            .frame(width: r.width, height: r.height)
                            .offset(x: r.minX, y: r.minY)
                    }
                }
                if workspace.layout == .dual || workspace.layout == .quad {
                    columnHandle(totalWidth: geo.size.width - grip)
                        .offset(x: (geo.size.width - grip) * workspace.splitRatioH)
                }
                if workspace.layout == .rows || workspace.layout == .quad {
                    rowHandle(totalHeight: geo.size.height - grip)
                        .offset(y: (geo.size.height - grip) * workspace.splitRatioV)
                }
            }
        }
    }

    /// Frame for pane `index` in the current layout, or nil if it isn't shown.
    private func rect(for index: Int, in size: CGSize) -> CGRect? {
        let availW = size.width - grip
        let col0 = availW * workspace.splitRatioH
        let col1 = availW - col0
        let col1X = col0 + grip
        let availH = size.height - grip
        let row0 = availH * workspace.splitRatioV
        let row1 = availH - row0
        let row1Y = row0 + grip

        switch workspace.layout {
        case .single:
            return index == 0 ? CGRect(x: 0, y: 0, width: size.width, height: size.height) : nil
        case .dual:
            switch index {
            case 0: return CGRect(x: 0, y: 0, width: col0, height: size.height)
            case 1: return CGRect(x: col1X, y: 0, width: col1, height: size.height)
            default: return nil
            }
        case .rows:
            switch index {
            case 0: return CGRect(x: 0, y: 0, width: size.width, height: row0)
            case 1: return CGRect(x: 0, y: row1Y, width: size.width, height: row1)
            default: return nil
            }
        case .quad:
            switch index {
            case 0: return CGRect(x: 0, y: 0, width: col0, height: row0)
            case 1: return CGRect(x: col1X, y: 0, width: col1, height: row0)
            case 2: return CGRect(x: 0, y: row1Y, width: col0, height: row1)
            case 3: return CGRect(x: col1X, y: row1Y, width: col1, height: row1)
            default: return nil
            }
        }
    }

    private func pane(_ index: Int) -> some View {
        PaneView(workspace: workspace, index: index)
    }

    private func columnHandle(totalWidth: CGFloat) -> some View {
        DragDividerHandle(
            orientation: .vertical,
            read: { workspace.splitRatioH * totalWidth },
            write: { workspace.splitRatioH = WorkspaceModel.clampSplitRatio($0 / max(totalWidth, 1)) },
            onEnded: { workspace.save() }
        )
        .frame(width: grip)
    }

    private func rowHandle(totalHeight: CGFloat) -> some View {
        DragDividerHandle(
            orientation: .horizontal,
            read: { workspace.splitRatioV * totalHeight },
            write: { workspace.splitRatioV = WorkspaceModel.clampSplitRatio($0 / max(totalHeight, 1)) },
            onEnded: { workspace.save() }
        )
        .frame(height: grip)
    }
}
