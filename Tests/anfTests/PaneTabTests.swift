import Foundation
@testable import anf

/// PaneModel tab lifecycle — switching tabs must show the SELECTED tab's folder
/// (the "wrong folder under a tab" regression class), closing must clamp the
/// active index, cycling must wrap, and a locked tab must snap back to its
/// pinned folder on activation (issue #14).
func runPaneTabTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        func pump(_ m: BrowserModel, until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        func dir(_ tag: String) -> URL {
            let u = fm.temporaryDirectory.appendingPathComponent("anfpane-\(tag)-\(UUID().uuidString)")
            try? fm.createDirectory(at: u, withIntermediateDirectories: true)
            return u
        }
        let a = dir("a"), b = dir("b"), c = dir("c")
        defer { [a, b, c].forEach { try? fm.removeItem(at: $0) } }

        T.group("selecting / cycling tabs surfaces that tab's folder via `current`") {
            let pane = PaneModel(start: a)
            pane.newTab(at: b)
            pane.newTab(at: c)
            T.equal(pane.tabs.count, 3, "three tabs")
            pane.select(0)
            T.equal(pane.current.currentURL.standardizedFileURL.path, a.standardizedFileURL.path, "tab 0 shows a")
            pane.select(2)
            T.equal(pane.current.currentURL.standardizedFileURL.path, c.standardizedFileURL.path, "tab 2 shows c")
            pane.cycle(1)
            T.equal(pane.activeIndex, 0, "cycle past the end wraps to 0")
            T.equal(pane.current.currentURL.standardizedFileURL.path, a.standardizedFileURL.path, "wrapped to a")
            pane.cycle(-1)
            T.equal(pane.activeIndex, 2, "cycle back from 0 wraps to the last")
        }

        T.group("closeTab guards the last tab and keeps activeIndex in range") {
            let pane = PaneModel(start: a)
            pane.newTab(at: b)
            pane.newTab(at: c)        // tabs: [a,b,c], active = 2
            pane.closeTab(2)          // close the active last tab
            T.equal(pane.tabs.count, 2, "tab removed")
            T.expect(pane.tabs.indices.contains(pane.activeIndex), "activeIndex stays in range")
            T.equal(pane.current.currentURL.standardizedFileURL.path, b.standardizedFileURL.path, "fell back to b")
            pane.closeTab(0)          // tabs: [b]
            pane.closeTab(0)          // last tab — must be a no-op
            T.equal(pane.tabs.count, 1, "the final tab can't be closed")
        }

        T.group("a locked tab snaps back to its pinned folder on activation (#14)") {
            let pane = PaneModel(start: a)
            pane.newTab(at: b)        // tab 1 starts at b, active = 1
            pane.current.toggleLock() // lock tab 1 to b
            pane.current.navigate(to: c)   // drift it elsewhere
            pump(pane.current) { pane.current.currentURL.standardizedFileURL.path == c.standardizedFileURL.path }
            pane.select(0)            // leave the locked tab
            pane.select(1)            // return → activeIndex.didSet snaps it home
            T.equal(pane.current.currentURL.standardizedFileURL.path, b.standardizedFileURL.path,
                    "the locked tab returned to b on re-activation")
        }
    }
}
