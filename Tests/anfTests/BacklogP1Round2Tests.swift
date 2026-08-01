import Foundation
@testable import anf

/// #42 P1 round 2: setLayout grow must REUSE a pane already showing the split
/// folder (rebuilding its table is the entire ⌘1–4 cost on big folders), and
/// makeNewFolder under a live filter must actually land the rename (the filter
/// used to hide "untitled folder" so selection/rename never arrived).
func runBacklogP1Round2Tests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let key = "anf.workspace.v1"
        let backup = UserDefaults.standard.data(forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
        defer {
            if let backup { UserDefaults.standard.set(backup, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        func pump(until: () -> Bool) {
            // 30s, not 5: under midnight disk load (backups + mds) a fixture
        // listing can outlive a 5s deadline — that flake killed a nightly.
        // Healthy runs pass the condition in milliseconds either way.
        let deadline = Date().addingTimeInterval(30)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        T.group("setLayout grow reuses a pane already showing the split folder") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfgrow-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: dir) }

            let ws = WorkspaceModel()
            ws.setLayout(.dual)
            ws.panes[0].current.navigate(to: dir)
            ws.panes[1].current.navigate(to: dir)   // pane 1 already shows `dir`
            ws.activePane = 0
            ws.setLayout(.single)

            // Grow back to dual: pane 1 still holds one tab at `dir` — the model
            // must be REUSED (identity), not rebuilt (which forces SwiftUI to
            // recreate the whole table view).
            let before = ObjectIdentifier(ws.panes[1].current)
            ws.setLayout(.dual)
            T.equal(ObjectIdentifier(ws.panes[1].current), before,
                    "pane already at the split folder keeps its BrowserModel")

            // Point pane 1 elsewhere, shrink, grow again → must be REPLACED with
            // a model at the split folder.
            let other = fm.temporaryDirectory
            ws.panes[1].current.navigate(to: other)
            ws.setLayout(.single)
            let stale = ObjectIdentifier(ws.panes[1].current)
            ws.setLayout(.dual)
            T.expect(ObjectIdentifier(ws.panes[1].current) != stale,
                     "pane showing another folder is rebuilt at the split folder")
            T.equal(ws.panes[1].current.currentURL.standardizedFileURL.path,
                    ws.panes[0].current.currentURL.standardizedFileURL.path,
                    "the rebuilt pane starts at the folder being split")

            // A pane with MULTIPLE tabs is rebuilt too (reuse is single-tab only).
            ws.panes[1].newTab()
            ws.setLayout(.single)
            let multi = ObjectIdentifier(ws.panes[1].current)
            ws.setLayout(.dual)
            T.expect(ObjectIdentifier(ws.panes[1].current) != multi,
                     "multi-tab pane is reset when revealed by a grow")
        }

        T.group("makeNewFolder under a filter clears it and lands the rename (#42 P1)") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfnewf-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in ["report.pdf", "notes.txt"] {
                try? "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8)
            }
            defer { try? fm.removeItem(at: dir) }

            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump { m.fileItems.count == 2 }
            m.filterText = "rep"
            pump { m.fileItems.count == 1 }
            T.equal(m.fileItems.count, 1, "filter narrows to report.pdf")

            m.makeNewFolder()
            pump { m.editingItemID != nil }
            T.equal(m.filterText, "", "creating a folder drops the filter — the new folder must be visible")
            T.expect(m.items.contains { $0.name.hasPrefix("untitled") },
                     "the new folder is in the listing")
            T.equal(m.selectedItems.first?.name.hasPrefix("untitled"), true,
                    "the new folder is selected")
            T.notNil(m.editingItemID, "inline rename opened on it (Finder-style)")
        }
    }
}
