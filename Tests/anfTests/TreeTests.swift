import Foundation
@testable import anf

/// Inline folder expansion in list mode: toggling a folder splices its children
/// into `items` (indented by depth), and collapsing removes them — so selection
/// and keyboard nav keep working on the flattened tree.
func runTreeTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anftree-\(UUID().uuidString)")
        let sub = dir.appendingPathComponent("sub")
        do {
            try fm.createDirectory(at: sub, withIntermediateDirectories: true)
            for n in ["a.txt", "b.txt"] { try "x".write(to: dir.appendingPathComponent(n), atomically: true, encoding: .utf8) }
            for n in ["s1.txt", "s2.txt"] { try "x".write(to: sub.appendingPathComponent(n), atomically: true, encoding: .utf8) }
        } catch { T.expect(false, "fixture threw: \(error)"); return }
        defer { try? fm.removeItem(at: dir) }

        let model = BrowserModel(start: dir)
        func pump(until: () -> Bool) {
            let deadline = Date().addingTimeInterval(5)
            while !until() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
        }
        pump { model.items.count == 3 }     // a.txt, b.txt, sub
        T.equal(model.items.count, 3, "top level loaded (2 files + 1 folder)")
        model.viewMode = .list
        guard let subItem = model.items.first(where: { $0.name == "sub" }) else {
            T.expect(false, "sub folder not listed"); return
        }

        T.group("expand splices children with depth") {
            T.expect(model.isExpandable(subItem), "folder is expandable in list mode")
            model.toggleExpand(subItem)
            pump { model.items.contains { $0.name == "s1.txt" } }
            T.expect(model.items.contains { $0.name == "s1.txt" }, "child s1 spliced in")
            T.expect(model.items.contains { $0.name == "s2.txt" }, "child s2 spliced in")
            T.equal(model.depth(of: subItem), 0, "folder stays at depth 0")
            if let s1 = model.items.first(where: { $0.name == "s1.txt" }) {
                T.equal(model.depth(of: s1), 1, "child is depth 1")
                T.equal(model.parentRow(of: s1)?.name, "sub", "parentRow of a child is its folder (← target)")
            }
            T.expect(model.isExpanded(subItem), "folder marked expanded")
        }

        T.group("collapse with a selected child lands selection on the folder") {
            // re-expand and select a child
            model.toggleExpand(subItem)
            pump { model.items.contains { $0.name == "s1.txt" } }
            if let s1 = model.items.first(where: { $0.name == "s1.txt" }) {
                model.selection = [s1.id]
            }
            model.toggleExpand(subItem)   // collapse — child is now hidden
            T.equal(model.selectedItems.map(\.name), ["sub"],
                    "orphaned selection lands on the collapsed folder (no vanished cursor)")
        }

        T.group("collapse removes children") {
            T.expect(!model.items.contains { $0.name == "s1.txt" }, "children gone after collapse")
            T.equal(model.items.count, 3, "back to the flat listing")
            T.expect(!model.isExpanded(subItem), "folder no longer expanded")
        }
    }
}
