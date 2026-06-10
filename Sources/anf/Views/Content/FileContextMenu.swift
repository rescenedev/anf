import SwiftUI

/// Right-click menu for a file/folder. Mirrors the keyboard actions.
struct FileContextMenu: View {
    @Bindable var model: BrowserModel
    let item: FileItem

    var body: some View {
        Button("Open") { ensureSelected(); model.open(item) }

        if item.isBrowsableContainer {
            Button("Open Terminal Here") { FileOperations.openInTerminal(item.url) }
        }

        Divider()

        if model.selection.count > 1 {
            Button("Rename \(model.selection.count) Items…") { model.batchRename() }
        } else {
            Button("Rename…") { ensureSelected(); model.renameSelected() }
        }
        Button("Duplicate") { ensureSelected(); model.duplicateSelection() }

        Divider()

        Button("Copy") { ensureSelected(); model.copySelectionToPasteboard() }
        Button("Copy Path") { ensureSelected(); model.copyPathToPasteboard() }
        Button("Paste") { model.pasteFromPasteboard() }
        Button("Reveal in Finder") { ensureSelected(); model.revealSelection() }

        Divider()

        Button("Move to Trash", role: .destructive) { ensureSelected(); model.trashSelection() }
    }

    private func ensureSelected() {
        if !model.selection.contains(item.id) { model.selection = [item.id] }
    }
}
