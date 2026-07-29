import AppKit

/// End-to-end terminal smoke: opens the terminal drawer and waits for xterm.js
/// to signal page-ready — which only happens if the resource bundle shipped
/// inside the app actually loads (PTY spawn + WKWebView + bundle lookup).
/// Run with `ANF_TERMINAL_SMOKE=1 anf`; exits 0 on ready, 1 on timeout.
/// This exists because v1.0.0 shipped without anf_anf.bundle: the terminal (and
/// any non-ko/en locale) crashed on every machine that wasn't the dev machine,
/// where Bundle.module silently fell back to the local `.build` tree.
@MainActor
enum TerminalSmoke {
    static var isRequested: Bool {
        ProcessInfo.processInfo.environment["ANF_TERMINAL_SMOKE"] == "1"
    }

    static func run(workspace: WorkspaceModel) {
        guard isRequested else { return }
        // A class box, not a captured var: the observer block is Sendable, and
        // mutating a captured local inside it is a Swift 6 data-race error.
        final class TokenBox: @unchecked Sendable { var token: NSObjectProtocol? }
        let box = TokenBox()
        box.token = NotificationCenter.default.addObserver(
            forName: .init("anf.terminal.pageReady"), object: nil, queue: .main
        ) { _ in
            if let token = box.token { NotificationCenter.default.removeObserver(token) }
            print("TERMINALSMOKE OK (bundle: \(anfResourceBundle?.bundlePath ?? "nil"))")
            exit(0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            workspace.toggleTerminal()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10.0) {
            print("TERMINALSMOKE FAIL — xterm page never became ready "
                  + "(bundle: \(anfResourceBundle?.bundlePath ?? "nil"))")
            exit(1)
        }
    }
}
