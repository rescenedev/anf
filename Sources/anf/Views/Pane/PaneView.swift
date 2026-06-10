import SwiftUI

/// A single panel: its tab strip, the file content for the active tab, and a path
/// bar. Highlights when it's the focused pane (only meaningful in 2/4 layouts).
struct PaneView: View {
    @Bindable var workspace: WorkspaceModel
    let index: Int

    @State private var paneHeight: CGFloat = 0

    private var pane: PaneModel { workspace.panes[index] }
    private var isActive: Bool { workspace.activePane == index }
    private var multiPane: Bool { workspace.layout.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            TabStripView(workspace: workspace, index: index)
            Divider()
            ContentArea(model: pane.current)
            PathBarView(model: pane.current)
            TerminalPanel(pane: pane, availableHeight: paneHeight)
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { paneHeight = geo.size.height }
                    .onChange(of: geo.size.height) { _, h in paneHeight = h }
            }
        )
        .animation(.easeInOut(duration: 0.2), value: pane.showTerminal)
        .overlay(alignment: .top) {
            if multiPane && isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .background(
            multiPane && isActive
                ? Color.accentColor.opacity(0.04) : Color.clear
        )
        // Focus this pane on any interaction without blocking child gestures.
        .simultaneousGesture(TapGesture().onEnded { workspace.focusPane(index) })
    }
}
