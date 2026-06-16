import Foundation
@testable import anf

/// Back/forward navigation history — core chrome (⌘← / ⌘→) that had ZERO
/// coverage. The risky part is the selection reconciliation on goBack: returning
/// to an ancestor must re-select the child we descended into (selectReturning →
/// selectChildWhenLoaded), which is the same async-reload + standardized-path
/// matching family that produced #36.
func runNavHistoryTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        func pump(_ m: BrowserModel, until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        // parent/{child(dir)/x.txt, sibling.txt}
        let parent = fm.temporaryDirectory.appendingPathComponent("anfnav-\(UUID().uuidString)")
        let child = parent.appendingPathComponent("child")
        try? fm.createDirectory(at: child, withIntermediateDirectories: true)
        try? "x".write(to: child.appendingPathComponent("x.txt"), atomically: true, encoding: .utf8)
        try? "s".write(to: parent.appendingPathComponent("sibling.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: parent) }

        T.group("goBack returns to the parent and re-selects the child we came from") {
            let m = BrowserModel(start: parent)
            m.viewMode = .list
            pump(m) { m.items.contains { $0.name == "child" } }
            guard let childItem = m.items.first(where: { $0.name == "child" }) else {
                T.expect(false, "child folder present"); return
            }
            m.open(childItem)   // descend (records history: back = [parent])
            pump(m) { m.currentURL.standardizedFileURL.path == child.standardizedFileURL.path }
            T.expect(m.canGoBack, "history has the parent after descending")
            m.goBack()
            pump(m) { m.currentURL.standardizedFileURL.path == parent.standardizedFileURL.path }
            T.equal(m.currentURL.standardizedFileURL.path, parent.standardizedFileURL.path, "back to parent")
            // The #36-class assertion: focus lands on the child, not the top row / "..".
            pump(m) { m.selectedItems.first?.name == "child" }
            T.equal(m.selectedItems.first?.name, "child", "the child we left is re-selected, not '..'")
        }

        T.group("goForward returns to the child; navigate clears the forward stack") {
            let m = BrowserModel(start: parent)
            m.viewMode = .list
            pump(m) { m.items.contains { $0.name == "child" } }
            m.open(m.items.first { $0.name == "child" }!)
            pump(m) { m.currentURL.standardizedFileURL.path == child.standardizedFileURL.path }
            m.goBack()
            pump(m) { m.currentURL.standardizedFileURL.path == parent.standardizedFileURL.path }
            T.expect(m.canGoForward, "forward stack holds the child after goBack")
            m.goForward()
            pump(m) { m.currentURL.standardizedFileURL.path == child.standardizedFileURL.path }
            T.equal(m.currentURL.standardizedFileURL.path, child.standardizedFileURL.path, "forward returns to child")
            T.expect(!m.canGoForward, "forward stack drained after goForward")
            // A fresh navigate must wipe the forward stack (no zombie redo).
            m.goBack()
            pump(m) { m.currentURL.standardizedFileURL.path == parent.standardizedFileURL.path }
            m.navigate(to: parent.appendingPathComponent("sibling.txt").deletingLastPathComponent())
            // (navigating to the same dir no-ops; instead descend child again to clear forward)
            m.open(m.items.first { $0.name == "child" }!)
            pump(m) { m.currentURL.standardizedFileURL.path == child.standardizedFileURL.path }
            T.expect(!m.canGoForward, "descending again cleared the old forward entry")
        }
    }
}
