import AppKit

/// Launches a terminal for anf. Prefers **Ghostty** (the user's terminal) and
/// falls back to Terminal.app. anf can't embed libghostty (not shipped as a
/// linkable library on macOS), so it drives Ghostty as a separate window instead.
@MainActor
enum TerminalLauncher {
    private static let ghosttyPath = "/Applications/Ghostty.app"
    private static var hasGhostty: Bool { FileManager.default.fileExists(atPath: ghosttyPath) }

    /// Open a new terminal at `directory`.
    static func openHere(_ directory: URL) {
        if hasGhostty {
            run(["-na", ghosttyPath, "--args", "--working-directory=\(directory.path)"])
        } else {
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.open([directory], withApplicationAt: terminal,
                                    configuration: NSWorkspace.OpenConfiguration())
        }
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
