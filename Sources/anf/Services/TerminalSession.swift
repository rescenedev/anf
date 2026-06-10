import AppKit
import Observation

/// An embedded terminal backed by xterm.js + a real PTY.
/// Replaces the previous SwiftTerm-based implementation.
@MainActor
@Observable
final class TerminalSession: NSObject, Identifiable {
    @ObservationIgnored let id = UUID()
    @ObservationIgnored let view: XtermTerminalView
    /// Set when this session is an `ssh <host>` connection.
    @ObservationIgnored let sshHost: String?
    private(set) var title: String
    private(set) var isRunning = true

    private init(title: String, sshHost: String? = nil) {
        self.title = title
        self.sshHost = sshHost
        view = XtermTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        super.init()
        view.onExit = { [weak self] in
            Task { @MainActor in self?.isRunning = false }
        }
    }

    static func shell(at directory: URL) -> TerminalSession {
        let session = TerminalSession(
            title: directory.lastPathComponent.isEmpty ? "/" : directory.lastPathComponent
        )
        session.view.startShell(at: directory)
        return session
    }

    static func ssh(_ host: String) -> TerminalSession {
        let session = TerminalSession(title: "ssh \(host)", sshHost: host)
        session.view.startSSH(args: [host])
        return session
    }

    static func ssh(_ custom: CustomSSHHost) -> TerminalSession {
        let session = TerminalSession(title: "ssh \(custom.target)", sshHost: custom.target)
        session.view.startSSH(args: custom.sshArgs)
        return session
    }

    func applyFontSize(_ size: CGFloat) {
        view.setFontSize(size)
    }

    func focus() {
        view.window?.makeFirstResponder(view)
        view.focus()
    }
}
