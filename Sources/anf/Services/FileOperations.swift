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

    /// Open items with a specific app (F4). `app` may be an app name ("Typora"),
    /// a path ("/Applications/Typora.app"), or a bundle id — `open -a` resolves
    /// all three.
    static func openWith(_ items: [FileItem], app: String) {
        let paths = items.map(\.url.path)
        guard !paths.isEmpty, !app.isEmpty else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app] + paths
        do { try p.run() }
        catch { presentFailures(L("Couldn’t open with \(app)", "\(app)(으)로 열지 못했습니다"), [error.localizedDescription]) }
    }

    /// Move to Trash. Returns (original, trashed-location) pairs — the trashed
    /// URL is what undo needs to put the file back.
    @discardableResult
    static func moveToTrash(_ items: [FileItem]) -> [(original: URL, trashed: URL)] {
        var pairs: [(original: URL, trashed: URL)] = []
        var noTrash: [FileItem] = []     // volume has no Trash (e.g. SMB/network shares)
        var failures: [String] = []
        let trashDir = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        for item in items {
            do {
                var trashedURL: NSURL?
                try FileManager.default.trashItem(at: item.url, resultingItemURL: &trashedURL)
                if let t = trashedURL as URL? {
                    pairs.append((item.url, t))
                } else if let dir = trashDir {
                    // trashItem succeeded but didn't report the trash location (observed
                    // on some AFP/third-party volume drivers — FO-001). Search the Trash
                    // for a file with the same name so undo can still restore it.
                    let name = item.url.lastPathComponent
                    if let found = try? FileManager.default.contentsOfDirectory(at: dir,
                        includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent == name }) {
                        pairs.append((item.url, found))
                    }
                }
            } catch let error as NSError
                        where error.domain == NSCocoaErrorDomain && error.code == NSFeatureUnsupportedError {
                noTrash.append(item)
            } catch {
                failures.append("\(item.name): \(error.localizedDescription)")
            }
        }
        if !pairs.isEmpty {
            FileUndo.shared.record(.trash(pairs))
        }
        // The volume can't trash these (no .Trashes — typical on network shares).
        // Offer immediate permanent deletion, Finder-style. NOT undoable.
        if !noTrash.isEmpty, confirmPermanentDelete(noTrash) {
            for item in noTrash {
                do { try FileManager.default.removeItem(at: item.url) }
                catch { failures.append("\(item.name): \(error.localizedDescription)") }
            }
        }
        presentFailures(L("Couldn’t move to Trash", "휴지통으로 이동하지 못했습니다"), failures)
        return pairs
    }

    /// Confirm permanent deletion of items the volume can't trash. Returns true if
    /// the user agrees. Headless (tests) declines — never silently destroys data.
    private static func confirmPermanentDelete(_ items: [FileItem]) -> Bool {
        guard NSApplication.shared.isRunning else { return false }
        let names = items.prefix(5).map(\.name).joined(separator: "\n")
            + (items.count > 5 ? L("\nand \(items.count - 5) more", "\n외 \(items.count - 5)건") : "")
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = items.count == 1
            ? L("Delete “\(items[0].name)” immediately?", "“\(items[0].name)”을(를) 즉시 삭제할까요?")
            : L("Delete \(items.count) items immediately?", "\(items.count)개 항목을 즉시 삭제할까요?")
        alert.informativeText = L(
            "This volume has no Trash. The items will be deleted immediately and can’t be undone.\n\n\(names)",
            "이 볼륨에는 휴지통이 없습니다. 항목이 즉시 삭제되며 되돌릴 수 없습니다.\n\n\(names)")
        alert.addButton(withTitle: L("Delete Immediately", "즉시 삭제"))
        alert.addButton(withTitle: L("Cancel", "취소"))
        return alert.runModal() == .alertFirstButtonReturn
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

    /// `recordUndo: false` lets a batch (RenamePanel / batchRename) coalesce all
    /// renames into ONE undo op instead of flooding the 50-deep stack with a record
    /// per file (RN-001) — the caller records `.move(pairs)` once.
    @discardableResult
    static func rename(_ item: FileItem, to newName: String, recordUndo: Bool = true) -> URL? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != item.name else { return nil }
        let dest = item.url.deletingLastPathComponent().appendingPathComponent(trimmed)
        do {
            try FileManager.default.moveItem(at: item.url, to: dest)
            if recordUndo { FileUndo.shared.record(.move([(from: item.url, to: dest)])) }
            return dest
        } catch {
            presentFailures(L("Couldn’t rename", "이름을 바꾸지 못했습니다"), ["\(item.name): \(error.localizedDescription)"])
            return nil
        }
    }

    /// Returns the created copy URLs so the caller can select them (issue #31:
    /// after ⌘D the copy is selected, ready to move/copy to the other pane).
    @discardableResult
    static func duplicate(_ items: [FileItem]) -> [URL] {
        let fm = FileManager.default
        var created: [URL] = []
        var failures: [String] = []
        for item in items {
            let dir = item.url.deletingLastPathComponent()
            let base = item.url.deletingPathExtension().lastPathComponent
            let ext = item.url.pathExtension
            // appendingPathExtension("") is undefined — on some runtime versions it
            // appends a trailing dot producing "Makefile copy." (FO-002). Build the
            // name via string interpolation (same as uniqueURL) when there's no ext.
            var dest = ext.isEmpty
                ? dir.appendingPathComponent("\(base) copy")
                : dir.appendingPathComponent("\(base) copy").appendingPathExtension(ext)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                dest = ext.isEmpty
                    ? dir.appendingPathComponent("\(base) copy \(n)")
                    : dir.appendingPathComponent("\(base) copy \(n)").appendingPathExtension(ext)
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
        return created
    }

    /// Next available "name", "name 2", "name 3"… in `dir`. `reserved` holds
    /// lowercased paths already claimed by an in-flight batch so two same-named
    /// sources don't both resolve to "name 2" and clobber each other (#76).
    static func uniqueURL(for name: String, in dir: URL, reserved: Set<String> = []) -> URL {
        let fm = FileManager.default
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var url = dir.appendingPathComponent(name)
        var n = 2
        while fm.fileExists(atPath: url.path) || reserved.contains(url.path.lowercased()) {
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
