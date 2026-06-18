import Foundation
@testable import anf

/// Native AppKit content views must focus their pane on mouse interaction even
/// when the clicked file is already selected and AppKit emits no selection delta.
func runPaneMouseFocusTests() {
    MainActor.assumeIsolated {
        T.group("native list mouse focus is independent of selection changes") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("anffocus-list-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            var focusCount = 0
            let model = BrowserModel(start: dir)
            let coordinator = FileListView.Coordinator(model: model) {
                focusCount += 1
            }

            coordinator.focusPaneFromMouse()
            T.equal(focusCount, 1, "list mouse focus callback fires without selection mutation")
        }

        T.group("native icon grid mouse focus is independent of selection changes") {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("anffocus-grid-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            var focusCount = 0
            let model = BrowserModel(start: dir)
            let coordinator = IconGridView.Coordinator(model: model) {
                focusCount += 1
            }

            coordinator.focusPaneFromMouse()
            T.equal(focusCount, 1, "grid mouse focus callback fires without selection mutation")
        }
    }
}
