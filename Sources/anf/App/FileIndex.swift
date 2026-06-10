import Foundation

/// Background filename index. A broad root (the home folder) is listed once with
/// `fd` at launch — just an in-memory array of paths, a few MB — and every folder
/// under it reuses that index, filtered to the focused folder by path prefix. So
/// the very first ⌘K search is already instant, with no per-search disk walk.
/// Folders outside the indexed root (e.g. other volumes) trigger a fresh index.
@MainActor
final class FileIndex {
    static let shared = FileIndex()

    private(set) var root: String?
    private(set) var entries: [URL] = []
    private(set) var ready = false
    private var task: Task<Void, Never>?

    /// Ensure `url` and below are covered. Reuses a broader index that already
    /// contains it; otherwise (re)builds rooted at `url`. No fd → no index.
    func build(for url: URL) {
        guard ExternalTools.path("fd") != nil else { root = nil; ready = false; entries = []; return }
        let path = url.standardizedFileURL.path
        if let root, ready, Self.isUnder(path, root) { return }   // already covered
        task?.cancel()
        root = path
        ready = false
        entries = []
        task = Task { [weak self] in
            let urls = await Task.detached(priority: .utility) { FileIndex.scan(path: path) }.value
            guard let self, self.root == path else { return }
            self.entries = urls
            self.ready = true
        }
    }

    /// Indexed entries scoped to `url` (and below), or nil if not covered/ready.
    func snapshot(for url: URL) -> [URL]? {
        let path = url.standardizedFileURL.path
        guard ready, let root, Self.isUnder(path, root) else { return nil }
        if path == root { return entries }
        return entries.filter { Self.isUnder($0.path, path) }
    }

    /// Distinct directory paths under `url` — for the scanning animation.
    func directories(for url: URL, limit: Int = 400) -> [String] {
        guard let snap = snapshot(for: url) else { return [] }
        var seen = Set<String>()
        var dirs: [String] = []
        for e in snap {
            let d = e.deletingLastPathComponent().path
            if seen.insert(d).inserted { dirs.append(d); if dirs.count >= limit { break } }
        }
        return dirs
    }

    private static func isUnder(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    nonisolated private static func scan(path: String) -> [URL] {
        let cap = 300_000
        guard let fd = ExternalTools.path("fd") else { return [] }
        // Respect .gitignore for speed (skips node_modules, build, .git, …).
        let lines = ExternalTools.run(fd, [
            "--color=never", "--absolute-path", "--type", "f", "--type", "d",
            "--max-results", "\(cap)", ".", path
        ], maxLines: cap, timeout: 20.0)
        return lines.map { URL(fileURLWithPath: $0) }
    }
}
