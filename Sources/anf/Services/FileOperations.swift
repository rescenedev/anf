import AppKit

/// Thin wrappers over Finder-style file actions. All user-facing, all on the main actor.
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

    /// Move to Trash. Returns the URLs that were trashed (for undo feedback).
    @discardableResult
    static func moveToTrash(_ items: [FileItem]) -> [URL] {
        var trashed: [URL] = []
        for item in items {
            do {
                try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                trashed.append(item.url)
            } catch {
                NSSound.beep()
            }
        }
        return trashed
    }

    /// Create a new uniquely-named folder inside `parent`. Returns its URL.
    @discardableResult
    static func newFolder(in parent: URL, baseName: String = "untitled folder") -> URL? {
        let fm = FileManager.default
        var url = parent.appendingPathComponent(baseName)
        var n = 2
        while fm.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(baseName) \(n)")
            n += 1
        }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            return url
        } catch {
            NSSound.beep()
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
            return dest
        } catch {
            NSSound.beep()
            return nil
        }
    }

    /// Copy source URLs into `destination`, auto-renaming on collision.
    static func copy(_ urls: [URL], into destination: URL) {
        for src in urls {
            let dest = uniqueURL(for: src.lastPathComponent, in: destination)
            do { try FileManager.default.copyItem(at: src, to: dest) } catch { NSSound.beep() }
        }
    }

    /// Move source URLs into `destination`, auto-renaming on collision.
    static func move(_ urls: [URL], into destination: URL) {
        for src in urls {
            let dest = uniqueURL(for: src.lastPathComponent, in: destination)
            do { try FileManager.default.moveItem(at: src, to: dest) } catch { NSSound.beep() }
        }
    }

    private static func uniqueURL(for name: String, in dir: URL) -> URL {
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

    static func duplicate(_ items: [FileItem]) {
        let fm = FileManager.default
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
            try? fm.copyItem(at: item.url, to: dest)
        }
    }
}
