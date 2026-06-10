import SwiftUI
import AppKit

/// NSViewRepresentable wrapper for XtermTerminalView.
struct XtermViewRep: NSViewRepresentable {
    let session: TerminalSession
    func makeNSView(context: Context) -> XtermTerminalView { session.view }
    func updateNSView(_ nsView: XtermTerminalView, context: Context) {}
}

/// The bottom terminal drawer shown inside a pane: drag handle, title bar, and
/// the live xterm.js terminal.
struct TerminalPanel: View {
    @Bindable var pane: PaneModel
    var availableHeight: CGFloat = 0

    var body: some View {
        if pane.showTerminal, let session = pane.terminal {
            VStack(spacing: 0) {
                DragDividerHandle(
                    orientation: .horizontal,
                    sign: -1,
                    read: { pane.terminalHeight },
                    write: {
                        pane.terminalHeightUserSet = true
                        pane.terminalHeight = PaneModel.clampTerminalHeight($0, available: availableHeight)
                    }
                )
                HStack(spacing: 6) {
                    Image(systemName: "terminal.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(session.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                    Spacer()
                    Button {
                        pane.showTerminal = false
                    } label: {
                        Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled().help("Close Terminal (⌃`)")
                }
                .padding(.horizontal, 10).frame(height: 24).background(.bar)
                XtermViewRep(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(height: pane.terminalHeight)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onAppear {
                // First open: take ~1/3 of the pane height so the prompt is visible.
                if !pane.terminalHeightUserSet, availableHeight > 0 {
                    pane.terminalHeight = PaneModel.clampTerminalHeight(
                        availableHeight / 3, available: availableHeight)
                }
            }
        }
    }
}
