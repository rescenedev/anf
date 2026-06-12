import Foundation
@testable import anf

/// Regression test for: QL preview panel not updating when the cursor moves
/// while the panel is open. The fix calls panel.reloadData() after each
/// selection-changing navigation. Here we verify the data layer: that
/// selectedItems (which feeds the panel) correctly reflects the new item
/// after every cursor movement, so the panel gets fresh data when reloaded.
func runQLPreviewSelectionTests() {
    MainActor.assumeIsolated {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anfqlsel-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for i in 1...4 {
                let name = String(format: "img%02d.jpg", i)
                try Data().write(to: dir.appendingPathComponent(name))
            }
        } catch { T.expect(false, "fixture setup threw: \(error)"); return }
        defer { try? fm.removeItem(at: dir) }

        let model = BrowserModel(start: dir)
        let deadline = Date().addingTimeInterval(5)
        while model.items.count != 4 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        T.equal(model.items.count, 4, "QL fixture listing loaded")
        guard model.items.count == 4 else { return }

        model.viewMode = .list

        T.group("QL preview: selectedItems URL changes on cursor down") {
            model.selection = [model.items[0].id]
            let before = model.selectedItems.first?.url
            T.equal(before, model.items[0].url, "initial selection is item 0")

            model.moveSelection(by: 1)

            let after = model.selectedItems.first?.url
            T.equal(after, model.items[1].url,
                    "selectedItems reflects item 1 after moveSelection(by:1)")
            T.expect(before != after,
                     "selectedItems URL must change so panel.reloadData() shows new preview")
        }

        T.group("QL preview: selectedItems URL changes on cursor up") {
            model.selection = [model.items[3].id]
            model.moveSelection(by: -1)
            T.equal(model.selectedItems.first?.url, model.items[2].url,
                    "selectedItems reflects item 2 after moveSelection(by:-1)")
        }

        T.group("QL preview: selectedItems URL changes on page down") {
            model.selection = [model.items[0].id]
            model.moveSelection(by: 3)   // jump to last
            T.equal(model.selectedItems.first?.url, model.items[3].url,
                    "selectedItems reflects last item after large positive delta")
        }

        T.group("QL preview: selectedItems URL changes on Home") {
            model.selection = [model.items[3].id]
            model.moveSelection(by: -model.items.count)
            T.equal(model.selectedItems.first?.url, model.items[0].url,
                    "selectedItems reflects first item after -items.count delta (Home)")
        }
    }
}
