import SwiftUI
import AppKit

/// NSViewRepresentable wrapper for XtermTerminalView.
struct XtermViewRep: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> XtermTerminalView { session.view }
    func updateNSView(_ nsView: XtermTerminalView, context: Context) {}
}

/// The global terminal drawer, shown at the bottom of the window's content area
/// across the full width below the pane split. One instance per window.
struct TerminalPanel: View {
    @Bindable var workspace: WorkspaceModel
    var availableHeight: CGFloat = 0

    var body: some View {
        if workspace.showTerminal, let session = workspace.terminal {
            VStack(spacing: 0) {
                DragDividerHandle(
                    orientation: .horizontal,
                    sign: -1,   // dragging up grows the drawer
                    read: { workspace.terminalHeight },
                    write: {
                        workspace.terminalHeightUserSet = true
                        workspace.terminalHeight = WorkspaceModel.clampTerminalHeight($0, available: availableHeight)
                    },
                    onEnded: { workspace.save() }
                )
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(session.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button {
                        workspace.showTerminal = false
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled().help("Close Terminal (⌃`)")
                }
                .padding(.horizontal, 10).frame(height: 24).background(.bar)
                // `.id` ties the embedded NSView to the session: when the user
                // switches host (e.g. ebs → msg10p) SwiftUI tears down the old
                // terminal view and builds the new session's, instead of keeping
                // the previous PTY on screen under a new title.
                XtermViewRep(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .id(session.id)
            }
            .frame(height: workspace.terminalHeight)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                // First open: take ~1/3 of the content height so the prompt shows.
                if !workspace.terminalHeightUserSet, availableHeight > 0 {
                    workspace.terminalHeight = WorkspaceModel.clampTerminalHeight(
                        availableHeight / 3, available: availableHeight)
                }
            }
        }
    }
}
