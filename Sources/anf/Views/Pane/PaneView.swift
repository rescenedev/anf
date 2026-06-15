import SwiftUI

/// A single panel: its tab strip, the file content for the active tab, and a path
/// bar. Highlights when it's the focused pane (only meaningful in 2/4 layouts).
struct PaneView: View {
    @Bindable var workspace: WorkspaceModel
    let index: Int

    private var pane: PaneModel { workspace.panes[index] }
    private var isActive: Bool { workspace.activePane == index }
    private var multiPane: Bool { workspace.layout.count > 1 }

    var body: some View {
        VStack(spacing: 0) {
            // The focus gestures live on this inner stack only — NOT the path bar.
            // A pane-wide `DragGesture(minimumDistance: 0)` fires on mouse-down and
            // swallows the path bar's breadcrumb button taps, so clicking a crumb
            // never navigated. Keeping it off the path bar restores those clicks;
            // PathBarView focuses the pane itself via `onFocus`.
            VStack(spacing: 0) {
                // Finder shows the tab bar only with 2+ tabs.
                if pane.tabs.count > 1 {
                    TabStripView(workspace: workspace, index: index)
                    Divider()
                }
                ContentArea(model: pane.current)
            }
            // Focus this pane on any interaction without blocking child gestures. A
            // zero-distance drag fires on mouse-down, so it also catches clicks on
            // the empty file-list area (an NSTableView swallows plain taps there).
            .simultaneousGesture(TapGesture().onEnded { workspace.focusPane(index) })
            .simultaneousGesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onEnded { _ in workspace.focusPane(index) }
            )
            if workspace.pathBarVisible {
                PathBarView(model: pane.current, onFocus: { workspace.focusPane(index) })
            }
        }
        .overlay(alignment: .top) {
            if multiPane && isActive {
                Rectangle().fill(Color.accentColor).frame(height: 2)
            }
        }
        .background(
            multiPane && isActive
                ? Color.accentColor.opacity(0.04) : Color.clear
        )
    }
}
