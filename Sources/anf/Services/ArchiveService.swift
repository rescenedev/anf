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

    /// How a given archive is extracted. `ditto`/`bsdtar` are on every Mac;
    /// `unar` (The Unarchiver) is optional and covers rar/alz/egg.
    enum Kind {
        case zip            // ditto — best Mac metadata preservation
        case libarchive     // bsdtar (built-in) — 7z, tar.*, cpio, xar, rpm, iso…
        case needsUnar      // rar / alz / egg / sit — needs `unar`
    }

    /// Classify an archive by its (possibly compound) extension, or nil if it's
    /// not an archive anf offers to extract. Pure — safe to call from anywhere.
    nonisolated static func kind(for url: URL) -> Kind? {
        let name = url.lastPathComponent.lowercased()
        // Compound tar variants first.
        if name.hasSuffix(".tar.gz") || name.hasSuffix(".tar.bz2")
            || name.hasSuffix(".tar.xz") || name.hasSuffix(".tar.zst")
            || name.hasSuffix(".tgz") || name.hasSuffix(".tbz") || name.hasSuffix(".txz") {
            return .libarchive
        }
        switch (name as NSString).pathExtension {
        case "zip": return .zip
        case "7z", "tar", "gz", "bz2", "xz", "zst", "cpio", "xar", "rpm",
             "iso", "jar", "war", "cbz": return .libarchive
        case "rar", "alz", "egg", "sit", "sitx", "lha", "lzh": return .needsUnar
        default: return nil
        }
    }

    /// Extract any supported archive into a uniquely-named folder next to it.
    static func extract(_ item: FileItem, completion: @escaping () -> Void) {
        guard let kind = kind(for: item.url) else { completion(); return }
        let dir = item.url.deletingLastPathComponent()
        // Strip the full archive suffix for the destination name (foo.tar.gz → foo).
        var base = item.url.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = (base as NSString).deletingPathExtension }
        let dest = FileOperations.uniqueURL(for: base, in: dir)

        // unar needs to be present; guide the user if it isn't.
        if kind == .needsUnar, ExternalTools.path("unar") == nil {
            FileOperations.presentFailures(
                L("This format needs ‘unar’", "이 형식은 ‘unar’가 필요합니다"),
                [L("Install it once with: brew install unar", "한 번만 설치하세요: brew install unar")])
            completion(); return
        }

        Task {
            let srcPath = item.url.path, destPath = dest.path
            let unar = ExternalTools.path("unar")
            let error = await Task.detached(priority: .userInitiated) { () -> String? in
                switch kind {
                case .zip:
                    return run("/usr/bin/ditto", ["-x", "-k", srcPath, destPath])
                case .libarchive:
                    // bsdtar needs the destination to exist; it writes contents into it.
                    try? FileManager.default.createDirectory(atPath: destPath,
                                                             withIntermediateDirectories: true)
                    return run("/usr/bin/bsdtar", ["-x", "-f", srcPath, "-C", destPath])
                case .needsUnar:
                    return run(unar!, ["-quiet", "-output-directory", destPath,
                                       "-force-overwrite", srcPath])
                }
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
        guard let trash = fm.urls(for: .trashDirectory, in: .userDomainMask).first else { completion(); return }
        guard let contents = try? fm.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil) else {
            // Without Full Disk Access the Trash reads as an error, not as
            // empty — surface the fix instead of silently doing nothing.
            let a = NSAlert()
            a.alertStyle = .warning
            a.messageText = L("Can’t access the Trash", "휴지통에 접근할 수 없습니다")
            a.informativeText = L("Allow anf under System Settings → Privacy & Security → Full Disk Access, then try again.",
                                  "시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한에서 anf를 허용한 뒤 다시 시도하세요.")
            a.addButton(withTitle: L("Open System Settings", "시스템 설정 열기"))
            a.addButton(withTitle: L("Cancel", "취소"))
            if a.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                NSWorkspace.shared.open(url)
            }
            completion(); return
        }
        guard !contents.isEmpty else { completion(); return }

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
