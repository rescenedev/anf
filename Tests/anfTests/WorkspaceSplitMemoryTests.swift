import Foundation
@testable import anf

/// Issue #42 (P1): the window-arrangement round trip and the pinned-folder split
/// memory. save()/restore() must reproduce the whole arrangement (layout, split
/// ratio, per-pane tabs + active tab, active pane), and a pin that had a split
/// going must bring that split back on the next pin click — across a relaunch.
/// NON-DESTRUCTIVE: both persistence keys are backed up and restored.
func runWorkspaceSplitMemoryTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let stateKey = "anf.workspace.v1"
        let pinKey = "anf.pinSnapshots.v1"
        let backups = [stateKey, pinKey].map { ($0, UserDefaults.standard.data(forKey: $0)) }
        defer {
            for (key, data) in backups {
                if let data { UserDefaults.standard.set(data, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        func cleanSlate() {
            UserDefaults.standard.removeObject(forKey: stateKey)
            UserDefaults.standard.removeObject(forKey: pinKey)
        }

        let root = fm.temporaryDirectory.appendingPathComponent("anfsm-\(UUID().uuidString)")
        let a = root.appendingPathComponent("a")
        let b = root.appendingPathComponent("b")
        let c = root.appendingPathComponent("c")
        for d in [a, b, c] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        defer { try? fm.removeItem(at: root) }
        @MainActor func path(_ m: BrowserModel) -> String { m.currentURL.standardizedFileURL.path }

        T.group("save→restore round trip: layout, ratio, tabs, active tab, active pane") {
            cleanSlate()
            let ws = WorkspaceModel()
            ws.setLayout(.dual)
            ws.panes[0].current.navigate(to: a)
            ws.panes[0].newTab(at: b)               // pane 0: [a, b], b active
            ws.panes[0].tabs[1].viewMode = .icons
            ws.panes[1].current.navigate(to: c)
            ws.splitRatioH = 0.3
            ws.activePane = 1
            ws.save()

            let ws2 = WorkspaceModel()
            T.expect(ws2.layout == .dual, "layout is restored")
            T.equal(Double(ws2.splitRatioH), 0.3, "split ratio is restored")
            T.equal(ws2.panes[0].tabs.count, 2, "pane 0 gets both tabs back")
            T.equal(ws2.panes[0].tabs.map(path), [a.path, b.path], "tab order survives")
            T.equal(ws2.panes[0].activeIndex, 1, "the active TAB survives")
            T.expect(ws2.panes[0].tabs[1].viewMode == .icons, "the tab's view mode survives")
            T.equal(ws2.panes[1].tabs.map(path), [c.path], "pane 1 comes back too")
            T.equal(ws2.activePane, 1, "the active PANE survives")
        }

        T.group("pin split memory: pin A's split survives relaunch and a detour to pin B") {
            cleanSlate()
            let ws = WorkspaceModel()
            ws.openPinned(a)                        // enter pin-A context (single pane)
            ws.setLayout(.dual)                     // split & arrange under it…
            ws.panes[1].current.navigate(to: c)
            ws.save()                               // …then "quit" mid-context

            let ws2 = WorkspaceModel()              // relaunch: dual arrangement restored
            ws2.setLayout(.single)                  // collapse OUTSIDE any pin context —
                                                    // A's remembered split must survive this
            ws2.openPinned(b)
            T.expect(ws2.layout == .single, "pin B never had a split → a plain navigation")
            T.equal(path(ws2.active), b.standardizedFileURL.path, "…to B")
            ws2.openPinned(a)
            T.expect(ws2.layout == .dual, "pin A brings its whole split back")
            T.equal(path(ws2.panes[0].current), a.standardizedFileURL.path, "left pane back on A")
            T.equal(path(ws2.panes[1].current), c.standardizedFileURL.path, "right pane back on C")

            T.group("…and collapsing INSIDE the pin context dissolves that memory") {
                ws2.setLayout(.single)              // now activePin is A → memory dropped
                ws2.openPinned(b)
                ws2.openPinned(a)
                T.expect(ws2.layout == .single, "A is a plain 'go there' again after the collapse")
                T.equal(path(ws2.active), a.standardizedFileURL.path, "it still navigates to A")
            }
        }

        T.group("applySnapshot filters dead paths: a vanished folder can't hollow out a pane") {
            cleanSlate()
            let dead = root.appendingPathComponent("gone-\(UUID().uuidString)").path
            let ws = WorkspaceModel()
            ws.active.navigate(to: a)
            let snap = ViewSnapshot(
                layout: "dual", activePane: 0, splitRatioH: 0.5, splitRatioV: 0.5,
                panes: [
                    .init(tabs: [.init(path: dead, viewMode: "list")], activeIndex: 0),
                    .init(tabs: [.init(path: c.path, viewMode: "list")], activeIndex: 0),
                ])
            ws.applySnapshot(snap)
            T.expect(ws.layout == .dual, "the layout still applies")
            T.equal(path(ws.panes[0].current), a.standardizedFileURL.path,
                    "an all-dead pane keeps its previous live tabs instead of going blank")
            T.equal(path(ws.panes[1].current), c.standardizedFileURL.path, "live paths do apply")
        }
    }
}
