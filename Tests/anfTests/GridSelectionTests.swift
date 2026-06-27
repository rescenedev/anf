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

        T.group("grouped icon grid: ↑/↓ respect per-group rows, not a uniform stride") {
            // cols=4. A:[0..6) rows [0-3][4-5]; B:[6..11) rows [6-9][10]; C:[11..13).
            // A uniform +cols stride lands on the wrong column across a group break.
            let groups = [FileGroup(title: "A", range: 0..<6),
                          FileGroup(title: "B", range: 6..<11),
                          FileGroup(title: "C", range: 11..<13)]
            func down(_ i: Int) -> Int { BrowserModel.groupAwareRowTarget(current: i, down: true,  cols: 4, groups: groups, itemCount: 13) }
            func up(_ i: Int)   -> Int { BrowserModel.groupAwareRowTarget(current: i, down: false, cols: 4, groups: groups, itemCount: 13) }
            T.equal(down(1), 5,  "within group: row0→row1 same col")
            T.equal(down(5), 7,  "A row1 col1 → B row0 col1 (not uniform +4 = 9)")
            T.equal(down(7), 10, "B row0 col1 → B's partial row1 last item")
            T.equal(down(10), 11, "B row1 col0 → C row0 col0")
            T.equal(down(12), 12, "last group, last item → clamp")
            T.equal(up(5), 1,    "within group: row1→row0 same col")
            T.equal(up(7), 5,    "B row0 col1 → A's last row, col1 (symmetric with down(5))")
            T.equal(up(11), 10,  "C row0 col0 → B's last row col0")
            T.equal(up(0), 0,    "first group, first item → clamp")
        }
    }
}
