import Foundation
@testable import anf

/// Selection-safety and keyboard×mouse interaction coverage — the bug class
/// behind #40 (stale selCursor after a mouse selection) and the ⌘A→Delete
/// safety guarantee around the synthetic ".." row.
func runSelectionSafetyTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        func pump(_ m: BrowserModel, until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        func makeFolder(_ files: [String]) -> URL {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfsel-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in files { try? "x".write(to: dir.appendingPathComponent(f), atomically: true, encoding: .utf8) }
            return dir
        }
        // A subfolder so the ".." row is present (showsParentRow needs canGoUp).
        let parent = fm.temporaryDirectory.appendingPathComponent("anfselp-\(UUID().uuidString)")
        let sub = parent.appendingPathComponent("sub")
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        for f in ["a.txt", "b.txt", "c.txt", "d.txt"] {
            try? "x".write(to: sub.appendingPathComponent(f), atomically: true, encoding: .utf8)
        }
        defer { try? fm.removeItem(at: parent) }

        T.group("selectAll() includes '..' in the set but never as an operable item") {
            let m = BrowserModel(start: sub)
            m.viewMode = .list
            pump(m) { m.items.contains { $0.isParentRef } && m.fileItems.count == 4 }
            m.selectAll()
            T.equal(m.selection.count, m.items.count, "every row, incl. '..', is in the selection set")
            T.equal(m.selectedItems.count, 4, "only the 4 real files are operable (⌘A→Delete can't hit '..')")
            T.expect(!m.selectedItems.contains { $0.isParentRef }, "no parent ref ever reaches a file op")
        }

        T.group("arrow after a mouse-style multi-select continues from a real row, never '..' (#40 class)") {
            let m = BrowserModel(start: sub)
            m.viewMode = .list
            pump(m) { m.items.contains { $0.isParentRef } && m.fileItems.count == 4 }
            let reals = m.items.filter { !$0.isParentRef }
            // Mouse multi-select two files via the SwiftUI binding (selection set
            // directly, selCursor left stale) — then press ↓.
            m.selection = Set([reals[1].id, reals[2].id])
            m.moveSelection(by: 1)
            T.equal(m.selectedItems.count, 1, "arrow collapses the multi-selection to one row")
            T.expect(!m.selectedItems.contains { $0.isParentRef }, "never lands on '..'")
            // Deterministic: continues from the listing-first of the multi-selection.
            T.equal(m.selectedItems.first?.id, reals[2].id, "↓ moves to the row after the first-selected file")
        }

        T.group("trashSelection deletes the target and leaves no dangling/'..' selection") {
            let dir = makeFolder(["a.txt", "b.txt", "c.txt"])
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump(m) { m.fileItems.count == 3 }
            guard let b = m.items.first(where: { $0.name == "b.txt" }) else {
                T.expect(false, "b.txt present"); return
            }
            m.select(b)
            m.trashSelection()
            pump(m) { m.fileItems.count == 2 }
            T.expect(!m.items.contains { $0.name == "b.txt" }, "b.txt was trashed")
            T.expect(!m.selectedItems.contains { $0.isParentRef }, "selection never points at '..' after a delete")
            // No selected id may reference a row that no longer exists.
            let liveIDs = Set(m.items.map(\.id))
            T.expect(m.selection.allSatisfy { liveIDs.contains($0) }, "no dangling selection id after reload")
        }
    }
}
