import Foundation
@testable import anf

/// The "terminalApp" preference → launch-target mapping (issue #61): known names
/// (case/space-insensitive), bundle ids, and custom app names/paths.
func runTerminalLauncherTests() {
    MainActor.assumeIsolated {
        T.group("terminalApp preference resolves to the right launch target (#61)") {
            T.equal(TerminalLauncher.target(for: ""), .auto, "empty → auto")
            T.equal(TerminalLauncher.target(for: "   "), .auto, "blank → auto")
            T.equal(TerminalLauncher.target(for: "auto"), .auto, "'auto' → auto")
            T.equal(TerminalLauncher.target(for: "Ghostty"), .ghostty, "ghostty (case-insensitive)")
            T.equal(TerminalLauncher.target(for: "terminal"), .named("Terminal"), "terminal → Terminal")
            T.equal(TerminalLauncher.target(for: "Terminal.app"), .named("Terminal"), "terminal.app alias")
            T.equal(TerminalLauncher.target(for: "iterm"), .named("iTerm"), "iterm → iTerm")
            T.equal(TerminalLauncher.target(for: "iTerm2"), .named("iTerm"), "iterm2 alias")
            T.equal(TerminalLauncher.target(for: "  iTerm  "), .named("iTerm"), "surrounding space trimmed")
            T.equal(TerminalLauncher.target(for: "Warp"), .named("Warp"), "unknown name → custom named app")
            T.equal(TerminalLauncher.target(for: "/Applications/Foo.app"),
                    .named("/Applications/Foo.app"), "a path (has '/') stays a named target")
            T.equal(TerminalLauncher.target(for: "com.googlecode.iterm2"),
                    .bundle("com.googlecode.iterm2"), "a bundle id ('.', no '/') → bundle target")
        }
    }
}
