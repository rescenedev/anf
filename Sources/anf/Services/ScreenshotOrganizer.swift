import Foundation

/// The real "tidy": sweep loose screenshots out of a folder and into a
/// `Screenshots/<YYYY-MM>` subfolder, grouped by capture month. Instant, no LLM
/// — renaming 1700 captures one-by-one was the wrong tool. Per-file AI naming
/// lives in SmartRename for the single file you actually care about.
enum ScreenshotOrganizer {

    struct Group: Sendable { let month: String; let urls: [URL] }
    struct Plan: Sendable {
        let groups: [Group]
        let destName: String
        var total: Int { groups.reduce(0) { $0 + $1.urls.count } }
    }

    /// Subfolder names we file into, in preference order — reuse an existing one
    /// (the user may already keep "_Screenshots") before making "Screenshots".
    private static let destCandidates = ["_Screenshots", "Screenshots"]

    /// Where screenshots should land (existing folder if present, else
    /// "Screenshots"). Returned even when it doesn't exist yet.
    static func destRoot(in folder: URL) -> URL {
        let fm = FileManager.default
        for name in destCandidates {
            let u = folder.appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return u }
        }
        return folder.appendingPathComponent("Screenshots")
    }

    /// Build the move plan (pure filesystem; call off the main thread). `find`
    /// is non-recursive, so screenshots already inside the dest folder are never
    /// re-swept.
    static func plan(in folder: URL) -> Plan {
        let destRoot = destRoot(in: folder)
        var buckets: [String: [URL]] = [:]
        guard let entries = FastDirRead.list(path: folder.path) else {
            return Plan(groups: [], destName: destRoot.lastPathComponent)
        }
        let cal = Calendar.current
        for e in entries where !e.isDir && !e.isHidden {
            let url = folder.appendingPathComponent(e.name)
            guard ScreenshotTidy.isScreenshot(url) else { continue }
            let date = e.created == .distantPast ? e.modified : e.created
            let c = cal.dateComponents([.year, .month], from: date)
            let key = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
            buckets[key, default: []].append(url)
        }
        let groups = buckets.keys.sorted(by: >).map { Group(month: $0, urls: buckets[$0]!) }
        return Plan(groups: groups, destName: destRoot.lastPathComponent)
    }

    /// Execute the move (call off the main thread). Returns moved/failed counts.
    static func move(_ plan: Plan, into folder: URL) -> (moved: Int, failed: Int, pairs: [(from: URL, to: URL)]) {
        let fm = FileManager.default
        let destRoot = destRoot(in: folder)
        var moved = 0, failed = 0
        var pairs: [(from: URL, to: URL)] = []
        for group in plan.groups {
            let dir = destRoot.appendingPathComponent(group.month)
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { failed += group.urls.count; continue }
            for src in group.urls {
                let name = uniqueName(in: dir, fileName: src.lastPathComponent)
                let dest = dir.appendingPathComponent(name)
                do {
                    try fm.moveItem(at: src, to: dest)
                    moved += 1; pairs.append((src, dest))
                } catch { failed += 1 }
            }
        }
        return (moved, failed, pairs)
    }

    /// A non-colliding name in `dir` (appends " 2", " 3"…).
    static func uniqueName(in dir: URL, fileName: String) -> String {
        let fm = FileManager.default
        let ns = fileName as NSString
        let ext = ns.pathExtension
        let base = ns.deletingPathExtension
        var n = 0
        while true {
            let stem = n == 0 ? base : "\(base) \(n)"
            let candidate = ext.isEmpty ? stem : "\(stem).\(ext)"
            if !fm.fileExists(atPath: dir.appendingPathComponent(candidate).path) { return candidate }
            n += 1
        }
    }
}
