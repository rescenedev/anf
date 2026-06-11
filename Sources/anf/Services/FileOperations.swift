import AppKit

/// Thin wrappers over Finder-style file actions. All user-facing, all on the main actor.
/// Mutating operations record themselves with `FileUndo` so ⌘Z can revert them,
/// and surface failures in one alert — errors are never silent.
@MainActor
enum FileOperations {

    static func open(_ item: FileItem) {
        NSWorkspace.shared.open(item.url)
    }

    static func reveal(_ items: [FileItem]) {
        NSWorkspace.shared.activateFileViewerSelecting(items.map(\.url))
    }

    static func openInTerminal(_ url: URL) {
        TerminalLauncher.openHere(url)
    }

    /// Move to Trash. Returns (original, trashed-location) pairs — the trashed
    /// URL is what undo needs to put the file back.
    @discardableResult
    static func moveToTrash(_ items: [FileItem]) -> [(original: URL, trashed: URL)] {
        var pairs: [(original: URL, trashed: URL)] = []
        var failures: [String] = []
        for item in items {
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashedURL)
                if let t = trashedURL as URL? { pairs.append((item.url, t)) }
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        if !pairs.isEmpty {
            FileUndo.shared.record(.trash(pairs))
        }
        presentFailures(L("Couldn’t move to Trash", "휴지통으로 이동하지 못했습니다"), failures)
        return pairs
    }

    /// Create a new uniquely-named folder inside `parent`. Returns its URL.
    @discardableResult
    static func newFolder(in parent: URL, baseName: String = "untitled folder") -> URL? {
        let url = uniqueURL(for: baseName, in: parent)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            FileUndo.shared.record(.created([url]))
            return url
        } catch {
            presentFailures(L("Couldn’t create folder", "폴더를 만들지 못했습니다"), [error.localizedDescription])
            return nil
        }
    }

    @discardableResult
    static func rename(_ item: FileItem, to newName: String) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            FileUndo.shared.record(.move([(from: item.url, to: dest)]))
            return dest
        } catch {
            presentFailures(L("Couldn’t rename", "이름을 바꾸지 못했습니다"), ["\(item.name): \(error.localizedDescription)"])
            return nil
        }
    }

    static func duplicate(_ items: [FileItem]) {
        let fm = FileManager.default
        var created: [URL] = []
        var failures: [String] = []
        for item in items {
            let dir = item.url.deletingLastPathComponent()
            let base = item.url.deletingPathExtension().lastPathComponent
            let ext = item.url.pathExtension
            var dest = dir.appendingPathComponent("\(base) copy")
                .appendingPathExtension(ext.isEmpty ? "" : ext)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = dir.appendingPathComponent("\(base) copy \(n)")
                    .appendingPathExtension(ext.isEmpty ? "" : ext)
                n += 1
            }
            do {
                try fm.copyItem(at: item.url, to: dest)
                created.append(dest)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        if !created.isEmpty { FileUndo.shared.record(.created(created)) }
        presentFailures(L("Couldn’t duplicate", "복제하지 못했습니다"), failures)
    }

    /// Next available "name", "name 2", "name 3"… in `dir`.
    static func uniqueURL(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            let candidate = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            url = dir.appendingPathComponent(candidate)
            n += 1
        }
        return url
    }

    /// One alert for a batch of failures — errors must never be silent.
    static func presentFailures(_ title: String, _ failures: [String]) {
        guard !failures.isEmpty else { return }
        // Headless (unit tests, self-tests): a modal alert would hang — log instead.
        guard NSApplication.shared.isRunning else {
            NSLog("[anf] %@: %@", title, failures.joined(separator: "; "))
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = failures.prefix(5).joined(separator: "\n")
            + (failures.count > 5 ? L("\nand \(failures.count - 5) more", "\n외 \(failures.count - 5)건") : "")
        alert.addButton(withTitle: L("OK", "확인"))
        alert.runModal()
    }
}
