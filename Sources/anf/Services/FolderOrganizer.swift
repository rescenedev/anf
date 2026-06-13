import Foundation

/// Tidy a messy folder (Downloads, especially) by sorting its loose files into
/// kind-based subfolders — Images, Documents, Archives, … — in one move.
/// Instant, no LLM. Folders are left untouched; unknown types stay put.
enum FolderOrganizer {

    /// A bucket: the localized folder name + the extensions that land in it.
    /// Order matters — the first category that matches an extension wins.
    struct Category { let key: String; let ko: String; let en: String; let exts: Set<String> }

    static let categories: [Category] = [
        Category(key: "images", ko: "이미지", en: "Images",
                 exts: ["png", "jpg", "jpeg", "heic", "heif", "gif", "webp", "tiff", "tif", "bmp", "svg", "raw", "cr2", "nef"]),
        Category(key: "videos", ko: "동영상", en: "Videos",
                 exts: ["mp4", "mov", "m4v", "avi", "mkv", "webm", "wmv", "flv"]),
        Category(key: "audio", ko: "오디오", en: "Audio",
                 exts: ["mp3", "m4a", "wav", "aac", "flac", "aiff", "ogg"]),
        Category(key: "pdf", ko: "PDF", en: "PDF", exts: ["pdf"]),
        Category(key: "documents", ko: "문서", en: "Documents",
                 exts: ["doc", "docx", "hwp", "hwpx", "ppt", "pptx", "xls", "xlsx",
                        "txt", "md", "markdown", "rtf", "csv", "pages", "key", "numbers", "epub"]),
        Category(key: "archives", ko: "압축파일", en: "Archives",
                 exts: ["zip", "tar", "gz", "tgz", "bz2", "xz", "7z", "rar", "dmg"]),
        Category(key: "installers", ko: "설치파일", en: "Installers",
                 exts: ["pkg", "app", "iso"]),
        Category(key: "code", ko: "코드", en: "Code",
                 exts: ["swift", "js", "ts", "jsx", "tsx", "py", "rb", "go", "rs",
                        "c", "h", "cpp", "java", "kt", "sh", "json", "yaml", "yml",
                        "html", "css", "xml", "sql"]),
    ]

    struct Group: Sendable { let folder: String; let urls: [URL] }
    struct Plan: Sendable {
        let groups: [Group]
        var total: Int { groups.reduce(0) { $0 + $1.urls.count } }
    }

    private static func categoryFolder(forExt ext: String, korean: Bool) -> String? {
        guard let c = categories.first(where: { $0.exts.contains(ext) }) else { return nil }
        return korean ? c.ko : c.en
    }

    /// The set of folder names we create, so we never re-sweep our own buckets.
    private static var bucketNames: Set<String> {
        Set(categories.flatMap { [$0.ko, $0.en] })
    }

    /// Build the move plan (pure filesystem; call off the main thread).
    static func plan(in folder: URL, korean: Bool) -> Plan {
        var buckets: [String: [URL]] = [:]
        guard let entries = FastDirRead.list(path: folder.path) else { return Plan(groups: []) }
        for e in entries where !e.isDir && !e.isHidden {
            let ext = (e.name as NSString).pathExtension.lowercased()
            guard !ext.isEmpty, let dest = categoryFolder(forExt: ext, korean: korean) else { continue }
            buckets[dest, default: []].append(folder.appendingPathComponent(e.name))
        }
        // Preserve declared category order for a tidy confirmation list.
        let order = categories.map { korean ? $0.ko : $0.en }
        let groups = order.compactMap { name in
            buckets[name].map { Group(folder: name, urls: $0) }
        }
        return Plan(groups: groups)
    }

    /// Execute the move (call off the main thread). Returns moved/failed counts.
    static func move(_ plan: Plan, into folder: URL) -> (moved: Int, failed: Int) {
        let fm = FileManager.default
        var moved = 0, failed = 0
        for group in plan.groups {
            let dir = folder.appendingPathComponent(group.folder)
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { failed += group.urls.count; continue }
            for src in group.urls {
                let name = ScreenshotOrganizer.uniqueName(in: dir, fileName: src.lastPathComponent)
                do { try fm.moveItem(at: src, to: dir.appendingPathComponent(name)); moved += 1 }
                catch { failed += 1 }
            }
        }
        return (moved, failed)
    }
}
