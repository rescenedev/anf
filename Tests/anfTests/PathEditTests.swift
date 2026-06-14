import Foundation
@testable import anf

/// Inline path editing (issue #14): `beginPathEdit()` signals the path bar to
/// open its editor, and `navigateToTypedPath()` navigates to a typed/pasted
/// path (with `~` expansion) while beeping on anything that isn't a reachable
/// directory.
func runPathEditTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        func pump(_ m: BrowserModel, until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        T.group("beginPathEdit bumps the editor-request counter") {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let m = BrowserModel(start: home)
            let before = m.pathEditRequests
            m.beginPathEdit()
            T.equal(m.pathEditRequests, before + 1, "one request after one call")
            m.beginPathEdit()
            T.equal(m.pathEditRequests, before + 2, "repeated ⌘L always re-triggers")
        }

        T.group("navigateToTypedPath moves to a real directory") {
            let parent = fm.temporaryDirectory.appendingPathComponent("anfpath-\(UUID().uuidString)")
            let child = parent.appendingPathComponent("sub")
            try? fm.createDirectory(at: child, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: parent) }
            let m = BrowserModel(start: parent)
            pump(m) { !m.isLoading }
            m.navigateToTypedPath("  \(child.path)  ")   // surrounding whitespace must be trimmed
            pump(m) { m.currentURL.standardizedFileURL.path == child.standardizedFileURL.path }
            T.equal(m.currentURL.standardizedFileURL.path, child.standardizedFileURL.path,
                    "navigates to the typed (trimmed) path")
        }

        T.group("navigateToTypedPath ignores empty and bogus paths") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfpath-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            pump(m) { !m.isLoading }
            let start = m.currentURL.standardizedFileURL.path

            m.navigateToTypedPath("   ")   // empty after trim — no-op, no crash
            m.navigateToTypedPath("/no/such/folder/anf-\(UUID().uuidString)")   // beeps, stays put
            // Give any detached validation a beat to (not) navigate.
            pump(m) { false }
            T.equal(m.currentURL.standardizedFileURL.path, start,
                    "empty and non-existent paths leave the location unchanged")
        }

        T.group("navigateToTypedPath expands a leading tilde") {
            let home = URL(fileURLWithPath: NSHomeDirectory())
            let m = BrowserModel(start: fm.temporaryDirectory)
            pump(m) { !m.isLoading }
            m.navigateToTypedPath("~")
            pump(m) { m.currentURL.standardizedFileURL.path == home.standardizedFileURL.path }
            T.equal(m.currentURL.standardizedFileURL.path, home.standardizedFileURL.path,
                    "~ expands to the home directory")
        }
    }
}
