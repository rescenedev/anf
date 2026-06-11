import AppKit

/// ZIP compress / extract via the system `ditto` and `zip` tools, off the main
/// thread. Results register with FileUndo so ⌘Z removes what was created.
@MainActor
enum ArchiveService {

    /// Compress `items` into a .zip next to them. One item keeps its name
    /// ("Folder.zip"); several become "Archive.zip".
    static func compress(_ items: [FileItem], completion: @escaping () -> Void) {
        guard let first = items.first else { return }
        let dir = first.url.deletingLastPathComponent()
        let baseName = items.count == 1 ? first.url.lastPathComponent : "Archive"
        let dest = FileOperations.uniqueURL(for: baseName + ".zip", in: dir)
        let paths = items.map(\.url.lastPathComponent)

        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                if paths.count == 1 {
                    // ditto preserves resource forks/metadata for a single tree.
                    let out = run("/usr/bin/ditto",
                                  ["-c", "-k", "--sequesterRsrc", "--keepParent",
                                   dir.appendingPathComponent(paths[0]).path, dest.path])
                    return out
                }
                // Multiple items: zip -r from the parent directory.
                return run("/usr/bin/zip", ["-r", "-q", dest.path] + paths, cwd: dir)
            }.value
            if let error {
                FileOperations.presentFailures(L("Couldn’t compress", "압축하지 못했습니다"), [error])
            } else {
                FileUndo.shared.record(.created([dest]))
            }
            completion()
        }
    }

    /// Extract a .zip into a uniquely-named folder next to it.
    static func extract(_ item: FileItem, completion: @escaping () -> Void) {
        let dir = item.url.deletingLastPathComponent()
        let base = item.url.deletingPathExtension().lastPathComponent
        let dest = FileOperations.uniqueURL(for: base, in: dir)
        Task {
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                run("/usr/bin/ditto", ["-x", "-k", item.url.path, dest.path])
            }.value
            if let error {
                FileOperations.presentFailures(L("Couldn’t extract", "압축을 풀지 못했습니다"), [error])
            } else {
                FileUndo.shared.record(.created([dest]))
            }
            completion()
        }
    }

    /// Empty the user's Trash after confirmation. Irreversible — says so.
    static func emptyTrash(completion: @escaping () -> Void) {
        let fm = FileManager.default
        guard let trash = fm.urls(for: .trashDirectory, in: .userDomainMask).first,
              let contents = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil),
              !contents.isEmpty else { completion(); return }

        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = L("Empty the Trash?", "휴지통을 비우시겠습니까?")
        alert.informativeText = L("\(contents.count) item(s) will be deleted permanently. This cannot be undone.", "\(contents.count)개 항목이 영구적으로 삭제됩니다. 되돌릴 수 없습니다.")
        alert.addButton(withTitle: L("Empty Trash", "비우기"))
        alert.addButton(withTitle: L("Cancel", "취소"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task {
            let failures = await Task.detached(priority: .userInitiated) { () -> [String] in
                var fails: [String] = []
                for url in contents {
                    do { try FileManager.default.removeItem(at: url) }
                    catch { fails.append("\(url.lastPathComponent): \(error.localizedDescription)") }
                }
                return fails
            }.value
            FileOperations.presentFailures(L("Some items couldn’t be deleted", "일부 항목을 삭제하지 못했습니다"), failures)
            completion()
        }
    }

    /// Run a tool; returns stderr/exit-description on failure, nil on success.
    nonisolated private static func run(_ exe: String, _ args: [String], cwd: URL? = nil) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        do { try p.run() } catch { return error.localizedDescription }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return msg.isEmpty ? L("exit code \(p.terminationStatus)", "종료 코드 \(p.terminationStatus)") : msg
        }
        return nil
    }
}
