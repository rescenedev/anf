import Foundation

/// Background filename index for the focused folder. When a folder is navigated
/// to, `fd` lists everything under it once (off the main thread); the palette
/// then fuzzy-filters that in-memory list per keystroke — no `fd` per search, so
/// filename search feels instant. Falls back to a per-query `fd` when the index
/// for the current folder isn't ready yet.
@MainActor
final class FileIndex {
    static let shared = FileIndex()

    private(set) var root: String?
    private(set) var entries: [URL] = []
    private(set) var ready = false
    private var task: Task<Void, Never>?

    /// Build (or reuse) the index for `url`. Cheap no-op if already indexed.
    func build(for url: URL) {
        let path = url.standardizedFileURL.path
        if path == root, ready { return }
        task?.cancel()
        root = path
        ready = false
        entries = []
        task = Task { [weak self] in
            let urls = await Task.detached(priority: .utility) {
                FileIndex.scan(path: path)
            }.value
            guard let self, self.root == path else { return }
            self.entries = urls
            self.ready = true
        }
    }

    /// The indexed entries for `url`, or nil if the index isn't ready for it.
    func snapshot(for url: URL) -> [URL]? {
        guard url.standardizedFileURL.path == root, ready else { return nil }
        return entries
    }

    /// Distinct directory paths in the index — used for the scanning animation.
    func directories(for url: URL, limit: Int = 400) -> [String] {
        guard url.standardizedFileURL.path == root, ready else { return [] }
        var seen = Set<String>()
        var dirs: [String] = []
        for e in entries {
            let d = e.deletingLastPathComponent().path
            if seen.insert(d).inserted { dirs.append(d); if dirs.count >= limit { break } }
        }
        return dirs
    }

    nonisolated private static func scan(path: String) -> [URL] {
        let cap = 150_000
        guard let fd = ExternalTools.path("fd") else { return [] }
        // Respect .gitignore for speed (skips node_modules, build, .git, …).
        let lines = ExternalTools.run(fd, [
            "--color=never", "--absolute-path", "--type", "f", "--type", "d",
            "--max-results", "\(cap)", ".", path
        ], maxLines: cap, timeout: 8.0)
        return lines.map { URL(fileURLWithPath: $0) }
    }
}
