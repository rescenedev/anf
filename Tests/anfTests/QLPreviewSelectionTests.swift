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
        T.equal(model.fileItems.count, 4, "QL fixture listing loaded")
        guard model.fileItems.count == 4 else { return }

        model.viewMode = .list

        // List mode shows the synthetic ".." row at index 0 (issue #12), so the
        // real files are fileItems[0...]; cursor math is verified against those.
        T.group("QL preview: selectedItems URL changes on cursor down") {
            model.selection = [model.fileItems[0].id]
            let before = model.selectedItems.first?.url
            T.equal(before, model.fileItems[0].url, "initial selection is the first file")

            model.moveSelection(by: 1)

            let after = model.selectedItems.first?.url
            T.equal(after, model.fileItems[1].url,
                    "selectedItems reflects the next file after moveSelection(by:1)")
            T.expect(before != after,
                     "selectedItems URL must change so panel.reloadData() shows new preview")
        }

        T.group("QL preview: selectedItems URL changes on cursor up") {
            model.selection = [model.fileItems[3].id]
            model.moveSelection(by: -1)
            T.equal(model.selectedItems.first?.url, model.fileItems[2].url,
                    "selectedItems reflects the previous file after moveSelection(by:-1)")
        }

        T.group("QL preview: selectedItems URL changes on page down") {
            model.selection = [model.fileItems[0].id]
            model.moveSelection(by: 3)   // jump to last
            T.equal(model.selectedItems.first?.url, model.fileItems[3].url,
                    "selectedItems reflects last item after large positive delta")
        }

        T.group("QL preview: Home reaches the top '..' row") {
            model.selection = [model.fileItems[3].id]
            model.moveSelection(by: -model.items.count)   // Home → very top
            // With the orthodox ".." row, Home lands on it; it has no preview.
            T.expect(model.cursorRowItem?.isParentRef == true, "Home reaches the '..' row")
            T.expect(model.selectedItems.isEmpty, "'..' carries no previewable selection")
        }
    }
}
