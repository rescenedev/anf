import Foundation
@testable import anf

/// #103 follow-up: user scripts surfaced in the ⌘K palette and run in the
/// built-in terminal. The terminal hop needs a GUI; the listing rules and the
/// command line handed to the shell are pure and tested here.
func runUserScriptsTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("anfscripts-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    UserScripts.directoryOverride = dir
    defer {
        UserScripts.directoryOverride = nil
        try? fm.removeItem(at: dir)
    }

    T.group("user script listing") {
        for name in ["b-convert.sh", "a plain", ".hidden.sh", "z.command"] {
            fm.createFile(atPath: dir.appendingPathComponent(name).path,
                          contents: Data("echo hi\n".utf8))
        }
        try? fm.createDirectory(at: dir.appendingPathComponent("subdir"),
                                withIntermediateDirectories: true)
        let names = UserScripts.list().map(\.lastPathComponent)
        T.equal(names, ["a plain", "b-convert.sh", "z.command"],
                "name-sorted; dotfiles and directories excluded")
    }

    T.group("user script command line") {
        let plain = dir.appendingPathComponent("a plain")
        T.equal(UserScripts.command(for: plain), "sh '\(dir.path)/a plain'",
                "non-executable runs via sh, path single-quoted against spaces")

        let exec = dir.appendingPathComponent("b-convert.sh")
        try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exec.path)
        T.equal(UserScripts.command(for: exec), "'\(dir.path)/b-convert.sh'",
                "executable runs directly")

        T.equal(UserScripts.shQuote("it's"), "'it'\\''s'",
                "embedded single quote escaped the POSIX way")
    }
}
