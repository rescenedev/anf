import Foundation
@testable import anf

/// The synthetic ".." parent row (issue #12, approach A): it appears at the top
/// of a list-mode folder, opening it goes up, and — critically — it is NEVER an
/// operable selection, so no file operation can act on the parent directory.
func runParentRowTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        func pump(_ m: BrowserModel, until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }

        // parent/child/{a.txt, b.txt}
        let parent = fm.temporaryDirectory.appendingPathComponent("anfparent-\(UUID().uuidString)")
        let child = parent.appendingPathComponent("child")
        try? fm.createDirectory(at: child, withIntermediateDirectories: true)
        try? "x".write(to: child.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try? "y".write(to: child.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        defer { try? fm.removeItem(at: parent) }

        T.group("'..' row appears at the top in a subfolder (list mode)") {
            let m = BrowserModel(start: child)
            m.viewMode = .list
            pump(m) { m.items.contains { $0.isParentRef } && m.items.contains { !$0.isParentRef } }
            T.expect(m.showsParentRow, "subfolder in list mode shows the parent row")
            T.expect(m.items.first?.isParentRef == true, "the first row is the synthetic '..'")
            T.equal(m.items.first?.name, "..", "its name is '..'")
            T.equal(m.items.filter { !$0.isParentRef }.count, 2, "two real files alongside it")
        }

        T.group("'..' is never an operable selection") {
            let m = BrowserModel(start: child)
            m.viewMode = .list
            pump(m) { m.items.contains { $0.isParentRef } && m.items.contains { !$0.isParentRef } }
            guard let parentRow = m.items.first(where: { $0.isParentRef }) else {
                T.expect(false, "parent row present"); return
            }
            // Even if it's in the selection set, selectedItems filters it out —
            // this is the safety chokepoint every file operation relies on.
            m.selection = [parentRow.id]
            T.equal(m.selectedItems.count, 0, "selecting '..' yields NO operable items")
            // Select-all-style: '..' + both files → only the 2 files are operable.
            m.selection = Set(m.items.map(\.id))
            T.equal(m.selectedItems.count, 2, "'..' excluded from a select-all")
            T.expect(!m.selectedItems.contains { $0.isParentRef }, "no parent ref in selectedItems")
        }

        T.group("opening '..' navigates up") {
            let m = BrowserModel(start: child)
            m.viewMode = .list
            pump(m) { m.items.contains { $0.isParentRef } && m.items.contains { !$0.isParentRef } }
            guard let parentRow = m.items.first(where: { $0.isParentRef }) else {
                T.expect(false, "parent row present before open"); return
            }
            m.open(parentRow)
            pump(m) { m.currentURL.standardizedFileURL.path == parent.standardizedFileURL.path }
            T.equal(m.currentURL.standardizedFileURL.path, parent.standardizedFileURL.path,
                    "open('..') goes up to the parent folder")
        }

        T.group("auto-selection lands on a real item, not '..'") {
            let m = BrowserModel(start: child)
            m.viewMode = .list
            pump(m) { !m.selection.isEmpty }
            T.expect(!m.selectedItems.contains { $0.isParentRef }, "initial selection is never the '..' row")
        }

        T.group("'..' suppressed where it makes no sense") {
            // Root has no parent.
            let root = BrowserModel(start: URL(fileURLWithPath: "/"))
            root.viewMode = .list
            T.expect(!root.showsParentRow, "root shows no parent row")
            // Recents (virtual) has no parent concept.
            let recents = BrowserModel(start: BrowserModel.recentsURL)
            recents.viewMode = .list
            T.expect(!recents.showsParentRow, "virtual locations show no parent row")
            // Icon mode is out of scope for this row.
            let icons = BrowserModel(start: child)
            icons.viewMode = .icons
            T.expect(!icons.showsParentRow, "icon mode shows no parent row (list-only feature)")
        }
    }
}
