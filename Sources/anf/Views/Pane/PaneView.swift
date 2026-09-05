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
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
                Text(BrowserModel.tabTitle(current: pane.current.currentURL, locked: pane.current.lockedURL))
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Text("\(pane.current.items.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .frame(height: 36)
            .background(Color(nsColor: .textBackgroundColor))
            .contentShape(Rectangle())
            .onTapGesture { workspace.focusPane(index) }
            Divider()
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
                ContentArea(
                    model: pane.current,
                    paneActive: isActive,
                    onFocus: { workspace.focusPane(index) }
                )
            }
            // Focus this pane on tap. Do NOT use a zero-distance SwiftUI DragGesture
            // here — it competes with AppKit file drag in icon/list views and the
            // drag ghost stops following the cursor (same lesson as DragDividerHandle).
            .simultaneousGesture(TapGesture().onEnded { workspace.focusPane(index) })
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
