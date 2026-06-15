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
    @State private var draggingH = false
    @State private var draggingV = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                ForEach(0..<4, id: \.self) { i in
                    // Hidden panes stay MOUNTED (zero frame, invisible) rather than
                    // unmounting: tearing one down destroys its NSTableView, and
                    // re-revealing it would rebuild a 26k-row listing. Kept alive,
                    // ⌘1–4 is pure geometry.
                    let r = rect(for: i, in: geo.size)
                    pane(i)
                        .frame(width: r?.width ?? 0, height: r?.height ?? 0)
                        .offset(x: r?.minX ?? 0, y: r?.minY ?? 0)
                        .opacity(r == nil ? 0 : 1)
                        .allowsHitTesting(r != nil)
                }
                if workspace.layout == .dual || workspace.layout == .quad {
                    columnHandle(totalWidth: geo.size.width - grip)
                        .offset(x: (geo.size.width - grip) * workspace.splitRatioH)
                }
                if workspace.layout == .rows || workspace.layout == .quad {
                    rowHandle(totalHeight: geo.size.height - grip)
                        .offset(y: (geo.size.height - grip) * workspace.splitRatioV)
                }
                // Live split-ratio readout while dragging a divider (issue #12).
                if draggingH {
                    splitBadge(WorkspaceModel.splitLabel(workspace.splitRatioH))
                        .position(x: (geo.size.width - grip) * workspace.splitRatioH + grip / 2,
                                  y: geo.size.height / 2)
                }
                if draggingV {
                    splitBadge(WorkspaceModel.splitLabel(workspace.splitRatioV))
                        .position(x: geo.size.width / 2,
                                  y: (geo.size.height - grip) * workspace.splitRatioV + grip / 2)
                }
            }
        }
    }

    /// Pill showing the current split (e.g. "60% · 40%") centred on the divider.
    private func splitBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold).monospacedDigit())
            .foregroundStyle(.primary)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(.regularMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
            .shadow(color: .black.opacity(0.15), radius: 4, y: 1)
            .allowsHitTesting(false)
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
            onBegan: { draggingH = true },
            onEnded: { draggingH = false; workspace.save() }
        )
        .frame(width: grip)
    }

    private func rowHandle(totalHeight: CGFloat) -> some View {
        DragDividerHandle(
            orientation: .horizontal,
            read: { workspace.splitRatioV * totalHeight },
            write: { workspace.splitRatioV = WorkspaceModel.clampSplitRatio($0 / max(totalHeight, 1)) },
            onBegan: { draggingV = true },
            onEnded: { draggingV = false; workspace.save() }
        )
        .frame(height: grip)
    }
}
