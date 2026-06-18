import AppKit

/// Launches a terminal for anf. The user picks one in the ⌘, settings file
/// ("terminalApp": "iterm" / "ghostty" / "terminal" / a custom app); unset/auto
/// prefers **Ghostty** (the user's terminal) and falls back to Terminal.app.
/// anf can't embed libghostty (not shipped as a linkable library on macOS), so
/// it drives the chosen terminal as a separate window instead.
@MainActor
enum TerminalLauncher {
    private static let ghosttyPath = "/Applications/Ghostty.app"
    private static var hasGhostty: Bool { FileManager.default.fileExists(atPath: ghosttyPath) }

    /// The user's "terminalApp" setting (mirrored to UserDefaults by Keymap from
    /// the ⌘, file). Raw value kept for custom app names/paths/bundle ids.
    private static var preferenceRaw: String {
        (UserDefaults.standard.string(forKey: "anf.terminalApp") ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Which terminal a "terminalApp" preference resolves to. `.auto` is decided
    /// at launch time (Ghostty if installed, else Terminal). Pure → unit-tested.
    enum Target: Equatable {
        case auto
        case ghostty
        case named(String)   // open -a <name|path>
        case bundle(String)  // open -b <bundle id>
    }

    /// Map a raw "terminalApp" value to a launch target. Case/space-insensitive
    /// for the known names; anything else is a custom app (#61).
    static func target(for preference: String) -> Target {
        let raw = preference.trimmingCharacters(in: .whitespacesAndNewlines)
        switch raw.lowercased() {
        case "", "auto":                              return .auto
        case "ghostty":                               return .ghostty
        case "terminal", "terminal.app", "apple", "macos", "default":
            return .named("Terminal")
        case "iterm", "iterm2", "iterm.app":          return .named("iTerm")
        default:
            // Custom: a bundle id (has ".", no "/") vs an app name or path.
            return (raw.contains(".") && !raw.contains("/")) ? .bundle(raw) : .named(raw)
        }
    }

    /// Open a new terminal at `directory`, honoring the user's choice (#61).
    static func openHere(_ directory: URL) {
        switch target(for: preferenceRaw) {
        case .auto:
            if hasGhostty { openGhostty(directory) } else { run(["-a", "Terminal", directory.path]) }
        case .ghostty:
            openGhostty(directory)
        case .named(let app):
            run(["-a", app, directory.path])    // `open -a <app> <dir>` → cwd = folder
        case .bundle(let id):
            run(["-b", id, directory.path])
        }
    }

    private static func openGhostty(_ directory: URL) {
        run(["-na", ghosttyPath, "--args", "--working-directory=\(directory.path)"])
    }

    /// Open a new terminal that immediately `ssh`'s into `host`.
    static func ssh(_ host: String) {
        if hasGhostty {
            run(["-na", ghosttyPath, "--args", "-e", "ssh", host])
        } else {
            // Terminal.app via an AppleScript `do script`.
            let script = "tell application \"Terminal\" to do script \"ssh \(host)\""
            if let appleScript = NSAppleScript(source: script) {
                appleScript.executeAndReturnError(nil)
            }
        }
    }

    private static func run(_ args: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = args
        try? process.run()
    }
}
