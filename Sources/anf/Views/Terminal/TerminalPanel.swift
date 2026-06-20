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
                // Session tabs: each open shell/ssh/sftp is a tab; × kills that
                // session's PTY. Hiding the drawer (⌃`) keeps sessions running.
                HStack(spacing: 4) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 4) {
                            ForEach(Array(workspace.terminals.enumerated()), id: \.element.id) { i, t in
                                terminalTab(t, index: i,
                                            active: i == workspace.activeTerminalIndex)
                            }
                        }
                    }
                    // New terminal tab: the terminal carries its own tabs, opened
                    // here rather than spawned per folder-tab (#76).
                    Button {
                        workspace.newTerminalTab()
                    } label: {
                        Image(systemName: "plus").font(.system(size: 10, weight: .bold))
                            .frame(width: 18, height: 18).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .help(L("New Terminal Tab", "새 터미널 탭"))
                    Spacer(minLength: 6)
                    Button {
                        workspace.showTerminal = false
                    } label: {
                        Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).focusEffectDisabled()
                    .help(L("Hide Terminal (⌃`)", "터미널 가리기 (⌃`)"))
                }
                .padding(.horizontal, 10).frame(height: 26).background(.bar)
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

    @ViewBuilder
    private func terminalTab(_ t: TerminalSession, index: Int, active: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: t.sshHost == nil ? "terminal.fill" : "network")
                .font(.system(size: 9))
                .foregroundStyle(t.isRunning ? (active ? Color.primary : Color.secondary) : Color.red)
            Text(t.title)
                .font(.system(size: 11, weight: active ? .semibold : .regular))
                .lineLimit(1)
                .foregroundStyle(active ? .primary : .secondary)
            Button {
                workspace.closeTerminal(at: index)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(L("Close Session", "세션 닫기"))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(active ? Color.primary.opacity(0.12) : .clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            workspace.activeTerminalIndex = index
            t.focus()
        }
        // Drag a terminal session tab to reorder it (issue #68).
        .draggable("\(index)")
        .dropDestination(for: String.self) { items, _ in
            guard let from = items.first.flatMap({ Int($0) }) else { return false }
            workspace.moveTerminal(from: from, to: index)
            return true
        }
    }
}
