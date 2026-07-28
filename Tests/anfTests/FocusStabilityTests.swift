import Foundation
@testable import anf

/// The #47 bug class, workspace-wide: a content refresh that ISN'T the user
/// navigating must never clear the selection — because `selection.didSet` fires
/// `onActivity`, and onActivity re-targets `activePane`. A plain `reload()` in a
/// background tab therefore both wiped that tab's selection AND yanked the pane
/// focus to whichever pane refreshed last. The file-op broadcast (dirsChangedNote)
/// and the pane-to-pane transfer callback did exactly that.
func runFocusStabilityTests() {
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
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        T.group("file-op broadcast keeps other panes' selection and focus (#47 class)") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anffocus-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try? "b".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: dir) }

            let ws = WorkspaceModel()
            ws.setLayout(.dual)
            // Both panes look at the same folder — the everyday split setup.
            let left = ws.panes[0].current, right = ws.panes[1].current
            left.navigate(to: dir); right.navigate(to: dir)
            pump { left.fileItems.count == 2 && right.fileItems.count == 2 }

            guard let a = right.items.first(where: { $0.name == "a.txt" }) else {
                T.expect(false, "fixture listed"); return
            }
            right.select(a)                 // selecting marks pane 1 active…
            ws.activePane = 0               // …then the user works in pane 0
            T.equal(right.selectedItems.first?.name, "a.txt", "right pane has a selection")

            // A file op in the LEFT pane broadcasts the folder it touched.
            try? "c".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
            NotificationCenter.default.post(
                name: BrowserModel.dirsChangedNote, object: nil,
                userInfo: ["dirs": Set([dir.standardizedFileURL.path]), "except": left.id])

            pump { right.items.contains { $0.name == "c.txt" } }
            T.expect(right.items.contains { $0.name == "c.txt" },
                     "the other pane picked up the new file")
            pump { right.selectedItems.first?.name == "a.txt" }
            T.equal(right.selectedItems.first?.name, "a.txt",
                    "the other pane's selection survives the broadcast refresh")
            T.equal(ws.activePane, 0,
                    "the broadcast refresh must not steal the active pane")
        }

        T.group("externalRefresh never fires onActivity; plain reload does") {
            // Pins the MECHANISM: focus stealing rides on selection.didSet →
            // onActivity, so the selection-preserving path must not write it.
            let dir = fm.temporaryDirectory.appendingPathComponent("anffocus2-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: dir) }

            let m = BrowserModel(start: dir)
            pump { m.fileItems.count == 1 }
            var fires = 0
            m.onActivity = { fires += 1 }

            m.externalRefresh()
            pump { !m.isLoading }
            T.equal(fires, 0, "externalRefresh is silent — no focus-affecting activity")

            m.reload()
            pump { !m.isLoading }
            T.expect(fires > 0, "plain reload clears the selection, which IS an activity signal")
        }

        T.group("after ⌘⌫ the nearest surviving row inherits the selection") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anffocus4-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for n in ["a.txt", "b.txt", "c.txt"] {
                try? "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8)
            }
            defer { try? fm.removeItem(at: dir) }

            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump { m.fileItems.count == 3 }
            guard let b = m.items.first(where: { $0.name == "b.txt" }) else {
                T.expect(false, "fixture listed"); return
            }
            m.select(b)
            m.trashSelection()
            pump { m.selectedItems.first?.name == "c.txt" }
            T.equal(m.fileItems.count, 2, "the file was trashed")
            T.equal(m.selectedItems.first?.name, "c.txt",
                    "the row after the deleted one is selected — keyboard flow continues")

            // Deleting the LAST row falls back to the new last row.
            m.trashSelection()
            pump { m.selectedItems.first?.name == "a.txt" }
            T.equal(m.selectedItems.first?.name, "a.txt",
                    "deleting the last row selects the new last row")
        }

        T.group("manual refresh (⌘R path) keeps the selection") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anffocus3-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try? "b".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: dir) }

            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump { m.fileItems.count == 2 }
            guard let a = m.items.first(where: { $0.name == "a.txt" }) else {
                T.expect(false, "fixture listed"); return
            }
            m.select(a)
            m.reload(preserveSelection: true)   // what the ⌘R keybinding now calls
            pump { !m.isLoading && m.selectedItems.first?.name == "a.txt" }
            T.equal(m.selectedItems.first?.name, "a.txt",
                    "refreshing the same folder keeps the user's place")
        }
    }
}
