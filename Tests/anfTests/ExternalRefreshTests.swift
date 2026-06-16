import Foundation
@testable import anf

/// `externalRefresh()` — the selection-preserving reload the live folder watcher
/// triggers when another app changes the current folder. It must surface the new
/// listing WITHOUT clearing the user's selection, and must defer while an inline
/// rename is open (so it doesn't yank the edit field).
func runExternalRefreshTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        func pump(_ m: BrowserModel, until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        T.group("externalRefresh surfaces a new file but keeps the selection") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfext-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            try? "b".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump(m) { m.fileItems.count == 2 }
            guard let a = m.items.first(where: { $0.name == "a.txt" }) else { T.expect(false, "a.txt present"); return }
            m.select(a)
            T.equal(m.selectedItems.first?.name, "a.txt", "a.txt is selected")
            // Another app creates a file in this folder.
            try? "c".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
            m.externalRefresh()
            // Wait for BOTH the new listing AND the async selection-restore to land.
            pump(m) { m.items.contains { $0.name == "c.txt" } && m.selectedItems.first?.name == "a.txt" }
            T.expect(m.items.contains { $0.name == "c.txt" }, "the externally-created file appears")
            T.equal(m.selectedItems.first?.name, "a.txt", "selection is preserved across the refresh")
        }

        T.group("externalRefresh drops a vanished selection without crashing") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfext2-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump(m) { m.fileItems.count == 1 }
            m.select(m.items.first { $0.name == "a.txt" }!)
            // The selected file disappears (deleted by another app), refresh.
            try? fm.removeItem(at: dir.appendingPathComponent("a.txt"))
            m.externalRefresh()
            pump(m) { m.fileItems.isEmpty }
            T.expect(m.fileItems.isEmpty, "the folder reads as empty")
            T.expect(!m.selectedItems.contains { $0.isParentRef }, "no '..' left selected")
            let live = Set(m.items.map(\.id))
            T.expect(m.selection.allSatisfy { live.contains($0) }, "no dangling selection id")
        }

        T.group("externalRefresh defers while an inline rename is open") {
            let dir = fm.temporaryDirectory.appendingPathComponent("anfext3-\(UUID().uuidString)")
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            try? "a".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            defer { try? fm.removeItem(at: dir) }
            let m = BrowserModel(start: dir)
            m.viewMode = .list
            pump(m) { m.fileItems.count == 1 }
            m.select(m.items.first { $0.name == "a.txt" }!)
            m.beginRename()
            T.expect(m.editingItemID != nil, "rename is in progress")
            try? "c".write(to: dir.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
            m.externalRefresh()   // must be a no-op so the edit field isn't yanked
            T.expect(m.editingItemID != nil, "the inline rename survives the deferred refresh")
        }
    }
}
