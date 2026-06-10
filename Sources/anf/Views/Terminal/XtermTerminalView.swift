import AppKit
import WebKit

/// Terminal view built on xterm.js + WKWebView, backed by a real PTY.
/// Significantly faster rendering than SwiftTerm on large outputs.
final class XtermTerminalView: NSView {
    private let webView: WKWebView
    private let pty = PTYProcess()
    private var ready = false
    private var pendingFontSize: CGFloat?

    var onTitleChange: ((String) -> Void)?
    var onExit: (() -> Void)?

    // Prevent accidental window-move when clicking inside the terminal.
    override var mouseDownCanMoveWindow: Bool { false }
    // Allow the terminal to receive clicks even when the window is in the background.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame: NSRect) {
        let cfg = WKWebViewConfiguration()
        cfg.preferences.setValue(true, forKey: "developerExtrasEnabled")
        cfg.userContentController.add(WeakScriptHandler(), name: "placeholder") // filled below
        let wv = WKWebView(frame: .zero, configuration: cfg)
        wv.setValue(false, forKey: "drawsBackground")
        // Disable WKWebView's own elastic scrolling so xterm.js handles scrollback.
        wv.enclosingScrollView?.verticalScrollElasticity = .none
        wv.enclosingScrollView?.horizontalScrollElasticity = .none
        wv.autoresizingMask = [.width, .height]
        webView = wv
        super.init(frame: frame)
        addSubview(wv)
        wv.frame = bounds

        let handlers = ScriptHandlers(view: self)
        cfg.userContentController.removeScriptMessageHandler(forName: "placeholder")
        cfg.userContentController.add(handlers, name: "input")
        cfg.userContentController.add(handlers, name: "resize")
        cfg.userContentController.add(handlers, name: "ready")

        loadPage()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Launch process

    func startShell(at directory: URL) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        pty.onOutput = { [weak self] data in self?.send(data: data) }
        pty.onExit   = { [weak self] _ in self?.onExit?() }
        pty.spawn(executable: shell, args: ["-il"],
                  environment: ["HOME": NSHomeDirectory()],
                  cwd: directory.path)
    }

    func startSSH(args: [String]) {
        pty.onOutput = { [weak self] data in self?.send(data: data) }
        pty.onExit   = { [weak self] _ in self?.onExit?() }
        pty.spawn(executable: "/usr/bin/ssh", args: args)
    }

    func startSFTP(args: [String]) {
        pty.onOutput = { [weak self] data in self?.send(data: data) }
        pty.onExit   = { [weak self] _ in self?.onExit?() }
        pty.spawn(executable: "/usr/bin/sftp", args: args)
    }

    func setFontSize(_ size: CGFloat) {
        if ready {
            webView.evaluateJavaScript("window.termSetFontSize(\(size))")
        } else {
            pendingFontSize = size
        }
    }

    func focus() { webView.window?.makeFirstResponder(webView) }

    func terminate() { pty.kill() }

    // MARK: - Internals

    private func loadPage() {
        guard let url = Bundle.module.url(forResource: "terminal", withExtension: "html",
                                          subdirectory: "xterm") else {
            // Fallback: load from build directory
            let fallback = URL(fileURLWithPath: #file)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Resources/xterm/terminal.html")
            webView.loadFileURL(fallback, allowingReadAccessTo: fallback.deletingLastPathComponent())
            return
        }
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }

    fileprivate func pageReady() {
        ready = true
        if let size = pendingFontSize { setFontSize(size); pendingFontSize = nil }
        // Give WKWebView first-responder status so keyboard and scroll events arrive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.focus()
        }
    }

    fileprivate func handleInput(_ string: String) {
        pty.write(string)
    }

    fileprivate func handleResize(cols: Int, rows: Int) {
        pty.resize(cols: cols, rows: rows)
    }

    private func send(data: Data) {
        // Base64-encode binary PTY output so JSON doesn't break on control chars
        let b64 = data.base64EncodedString()
        webView.evaluateJavaScript(
            "window.termWrite(Uint8Array.from(atob('\(b64)'),c=>c.charCodeAt(0)))"
        )
    }
}

// MARK: - Script message handler

private final class ScriptHandlers: NSObject, WKScriptMessageHandler {
    weak var view: XtermTerminalView?
    init(view: XtermTerminalView) { self.view = view }

    func userContentController(_ controller: WKUserContentController,
                                didReceive message: WKScriptMessage) {
        guard let view else { return }
        switch message.name {
        case "input":
            if let s = message.body as? String { view.handleInput(s) }
        case "resize":
            if let d = message.body as? [String: Any],
               let c = d["cols"] as? Int, let r = d["rows"] as? Int {
                view.handleResize(cols: c, rows: r)
            }
        case "ready":
            view.pageReady()
        default: break
        }
    }
}

// Prevents retain cycle (WKWebView strongly retains script handlers).
private final class WeakScriptHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {}
}
