import Foundation
@testable import anf

/// Keyboard selection in the icon grid: rectangular shift-extension with the
/// anchor and cursor as opposite corners, deterministic anchor after a click,
/// and contiguous ranges in list mode. Drives a real BrowserModel over a
/// fixture folder (12 files → a 4×3 grid with gridColumns = 4).
func runGridSelectionTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anfgrid-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 1...12 {
                let name = String(format: "f%02d.txt", i)
                try "x".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
            }
        } catch { T.expect(false, "fixture setup threw: \(error)"); return }
        defer { try? fm.removeItem(at: dir) }

        let model = BrowserModel(start: dir)
        // reload() lands asynchronously — pump the main runloop until it does.
        let deadline = Date().addingTimeInterval(5)
        while model.items.count != 12 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        T.equal(model.fileItems.count, 12, "fixture listing loaded")
        guard model.fileItems.count == 12 else { return }

        model.viewMode = .icons
        model.gridColumns = 4
        @MainActor func names() -> [String] {
            model.items.filter { model.selection.contains($0.id) }.map(\.name)
        }

        T.group("icon grid: rectangular shift-extension") {
            model.selection = [model.items[0].id]            // "click" f01
            model.moveSelection(by: 4, extend: true)         // shift+↓
            T.equal(names(), ["f01.txt", "f05.txt"], "shift+↓ selects the cell below")
            model.moveSelection(by: 4, extend: true)         // shift+↓
            T.equal(names(), ["f01.txt", "f05.txt", "f09.txt"], "second shift+↓ grows the column")
            model.moveSelection(by: 1, extend: true)         // shift+→
            T.equal(names(), ["f01.txt", "f02.txt", "f05.txt", "f06.txt", "f09.txt", "f10.txt"],
                    "shift+→ widens to a 2×3 rectangle (not a snake trail)")
        }

        T.group("icon grid: backtracking shrinks the block") {
            model.moveSelection(by: -1, extend: true)        // shift+←
            T.equal(names(), ["f01.txt", "f05.txt", "f09.txt"], "shift+← narrows back to one column")
            model.moveSelection(by: -4, extend: true)        // shift+↑
            T.equal(names(), ["f01.txt", "f05.txt"], "shift+↑ shortens the column")
        }

        T.group("icon grid: anchor resets after a click") {
            model.selection = [model.items[6].id]            // "click" f07 mid-grid
            model.moveSelection(by: 4, extend: true)         // shift+↓
            T.equal(names(), ["f07.txt", "f11.txt"],
                    "extension starts from the clicked cell, not a stale anchor")
        }

        T.group("icon grid: plain arrow collapses to one cell") {
            model.moveSelection(by: 1)
            T.equal(names(), ["f12.txt"], "arrow without shift selects a single cell")
        }

        T.group("icon grid: clamp at the partial last row") {
            model.selection = [model.items[8].id]            // f09, bottom row
            model.moveSelection(by: 4, extend: true)         // shift+↓ past the end
            T.equal(names(), ["f09.txt", "f10.txt", "f11.txt", "f12.txt"],
                    "cursor clamps to the last item; missing cells are skipped")
        }

        T.group("icon grid: ↑/↓ flip to next photo when there's no row that way") {
            // Single row (all 12 fit across): ↓/↑ must step one item, not snap
            // to the first/last (issue report 2026-06-13).
            model.gridColumns = 12
            model.selection = [model.items[0].id]
            model.moveSelection(by: 12, extend: false, rowJump: true)   // ↓ in a 1-row grid
            T.equal(names(), ["f02.txt"], "↓ on a single row moves to the next photo")
            model.moveSelection(by: -12, extend: false, rowJump: true)  // ↑
            T.equal(names(), ["f01.txt"], "↑ on a single row moves to the previous photo")

            // Last (partial) row: ↓ has no row below → steps to the next item.
            model.gridColumns = 4
            model.selection = [model.items[9].id]                       // f10, bottom row
            model.moveSelection(by: 4, extend: false, rowJump: true)
            T.equal(names(), ["f11.txt"], "↓ on the last row advances to the next item")

            // A real row below still jumps a whole row.
            model.selection = [model.items[0].id]                       // f01
            model.moveSelection(by: 4, extend: false, rowJump: true)
            T.equal(names(), ["f05.txt"], "↓ still jumps a full row when one exists")
        }

        T.group("list mode: contiguous reading-order range") {
            model.viewMode = .list
            model.selection = [model.fileItems[2].id]        // "click" f03 (items[0] is "..")
            model.moveSelection(by: 1, extend: true)
            model.moveSelection(by: 1, extend: true)
            T.equal(names(), ["f03.txt", "f04.txt", "f05.txt"], "shift+↓ grows a contiguous run")
            model.moveSelection(by: -1, extend: true)
            T.equal(names(), ["f03.txt", "f04.txt"], "shift+↑ retracts the run")
        }
    }
}
