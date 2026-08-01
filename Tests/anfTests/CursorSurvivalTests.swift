import Foundation
@testable import anf

/// Issue #42 (P1): the keyboard cursor/selection must survive listing reshuffles —
/// sort flips, filter text, Arrange-by grouping and view-mode switches all rebuild
/// `items`, and a stale `selCursor` index silently points at a different file (the
/// #40 bug class). Selection is keyed by FileItem.ID (the URL), so the contract is:
/// the same FILE stays selected, and the next arrow key continues from that file.
func runCursorSurvivalTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        // groupKey persists app-wide; keep the suite from leaking it into the app.
        let groupKeyBackup = UserDefaults.standard.string(forKey: "anf.groupKey")
        defer {
            if let g = groupKeyBackup { UserDefaults.standard.set(g, forKey: "anf.groupKey") }
            else { UserDefaults.standard.removeObject(forKey: "anf.groupKey") }
        }

        func pump(until: () -> Bool) {
            // 30s, not 5: under midnight disk load (backups + mds) a fixture
        // listing can outlive a 5s deadline — that flake killed a nightly.
        // Healthy runs pass the condition in milliseconds either way.
        let deadline = Date().addingTimeInterval(30)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        func makeFolder(files: [String], dirs: [String] = []) -> URL {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfcur-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files { try? "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
            for d in dirs { try? fm.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true) }
            return dir
        }

        T.group("sort flip keeps the selection on the same file; ↓ continues from it") {
            let dir = makeFolder(files: ["a.txt", "b.txt", "c.txt", "d.txt"])
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump { m.fileItems.count == 4 }
            guard let b = m.items.first(where: { $0.name == "b.txt" }) else {
                T.expect(false, "b.txt present"); return
            }
            m.select(b)                                   // selCursor now = b's ascending index
            m.sort = SortOrder(key: .name, ascending: false)   // reorder → that index is c.txt
            T.equal(m.selectedItems.map(\.name), ["b.txt"], "the sort flip didn't move the selection")
            T.equal(m.cursorRowItem?.name, "b.txt", "cursor re-derives from the selection, not the stale index")
            m.moveSelection(by: 1)
            T.equal(m.selectedItems.map(\.name), ["a.txt"],
                    "↓ continues from b.txt in the NEW (descending) order")
        }

        T.group("filter hides the selected file: the next arrow lands on a visible row") {
            let dir = makeFolder(files: ["a.txt", "b.txt", "note.md"])
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .icons               // no synthetic ".." row in the grid
            pump { m.fileItems.count == 3 }
            guard let a = m.items.first(where: { $0.name == "a.txt" }) else {
                T.expect(false, "a.txt present"); return
            }
            m.select(a)
            m.filterText = "md"               // a.txt is filtered out of `items`
            T.equal(m.selectedItems.count, 0, "a hidden file is not an operable selection")
            T.isNil(m.selectionCursorIndex, "no cursor index while the selected row is invisible")
            m.moveSelection(by: 1)
            T.equal(m.selectedItems.map(\.name), ["note.md"],
                    "arrow after a filtered-away selection lands on a visible row")
        }

        T.group("Arrange-by grouping: arrows walk the flat grouped order") {
            let dir = makeFolder(files: ["a.txt", "b.txt"], dirs: ["zfolder"])
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump { m.fileItems.count == 3 }
            m.groupKey = .kind
            defer { m.groupKey = .none }
            T.expect(m.grouped, "grouping is active")
            T.expect(!m.showsParentRow, "no '..' row while grouped (group rows own the index math)")
            T.equal(m.items.count, 3, "grouping keeps `items` flat — headers live only in the views")
            m.moveSelection(by: 1)            // empty selection → first row
            let first = m.selectedItems.first?.name
            T.equal(first, m.items[0].name, "first ↓ selects the first grouped row")
            m.moveSelection(by: 1)
            T.equal(m.selectedItems.first?.name, m.items[1].name, "↓ steps in grouped order")
            m.moveSelection(by: -1)
            T.equal(m.selectedItems.first?.name, m.items[0].name, "↑ steps back in grouped order")
        }

        T.group("list↔icons switch (the '..' row appears/vanishes) keeps the same file selected") {
            let dir = makeFolder(files: ["a.txt", "b.txt", "c.txt", "d.txt"])
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump { m.fileItems.count == 4 && m.items.contains { $0.isParentRef } }
            guard let b = m.items.first(where: { $0.name == "b.txt" }) else {
                T.expect(false, "b.txt present"); return
            }
            m.select(b)                       // index includes the ".." offset
            m.viewMode = .icons               // ".." removed → every index shifts by one
            T.equal(m.selectedItems.map(\.name), ["b.txt"], "selection survives list→icons by identity")
            T.equal(m.cursorRowItem?.name, "b.txt", "cursor doesn't slide onto the shifted neighbor")
            m.moveSelection(by: 1)
            T.equal(m.selectedItems.map(\.name), ["c.txt"], "↓ continues from the SAME file, not the same index")
            m.viewMode = .list                // ".." reinserted
            T.equal(m.selectedItems.map(\.name), ["c.txt"], "selection survives icons→list too")
        }

        T.group("makeNewFolder while grouped: focus + inline rename land on the new folder") {
            let dir = makeFolder(files: ["a.txt"], dirs: ["existing"])
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump { m.fileItems.count == 2 }
            m.groupKey = .kind
            defer { m.groupKey = .none }
            let before = Set(m.fileItems.map(\.url.lastPathComponent))
            m.makeNewFolder()
            pump { m.fileItems.count == 3 && !m.selection.isEmpty && m.editingItemID != nil }
            guard let fresh = m.fileItems.first(where: { !before.contains($0.url.lastPathComponent) }) else {
                T.expect(false, "the new folder appeared in the grouped listing"); return
            }
            T.equal(m.selectedItems.map(\.id), [fresh.id], "the new folder is the selection")
            T.equal(m.editingItemID, fresh.id, "inline rename begins on it (Finder-style, issue #31)")
            T.expect(fresh.isDirectory, "and it is actually a directory")
        }
    }
}
