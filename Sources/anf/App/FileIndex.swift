import Foundation

/// Background filename index for the focused folder, persisted to disk so it
/// survives quit/relaunch. On launch the last checkpoint is loaded instantly;
/// every focus/navigation refreshes the scan in the background (throttled) and
/// re-saves the checkpoint. The palette fuzzy-filters this in-memory list per
/// keystroke — no per-search disk walk. Without `fd` there's no index and the
/// palette falls back to mdfind / FileManager.
@MainActor
final class FileIndex {
    static let shared = FileIndex()

    private(set) var root: String?
    private(set) var entries: [URL] = []
    private(set) var ready = false
    private var task: Task<Void, Never>?
    private var seeded = false
    private var lastScan: [String: Date] = [:]

    /// Ensure `url` (and below) is indexed. Reuses a broader in-memory or
    /// on-disk index that already covers it; otherwise (re)builds rooted at `url`.
    func build(for url: URL) {
        guard ExternalTools.path("fd") != nil else { root = nil; ready = false; entries = []; return }
        let path = url.standardizedFileURL.path

        // Seed from the on-disk checkpoint once — instant availability on launch.
        if !seeded {
            seeded = true
            if let c = Self.loadCache() { root = c.root; entries = c.entries; ready = true }
        }

        if let r = root, ready, Self.isUnder(path, r) {
            // Re-index immediately if the focused folder changed (mtime bumped by
            // add/remove/rename of its contents); otherwise a throttled refresh.
            refresh(r, force: Self.folderChanged(url, since: lastScan[r]))
            return
        }
        root = path; entries = []; ready = false
        refresh(path, force: true)
    }

    private static func folderChanged(_ url: URL, since: Date?) -> Bool {
        guard let since else { return true }
        let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        return (m ?? .distantPast) > since
    }

    /// (Re)scan `rootPath` in the background and re-save the checkpoint. Throttled
    /// to avoid rescanning the same root on every focus change.
    private func refresh(_ rootPath: String, force: Bool = false) {
        if !force, let last = lastScan[rootPath], Date().timeIntervalSince(last) < 20 { return }
        lastScan[rootPath] = Date()
        task?.cancel()
        task = Task { [weak self] in
            let urls = await Task.detached(priority: .utility) { () -> [URL] in
                let u = FileIndex.scan(path: rootPath)
                FileIndex.saveCache(root: rootPath, entries: u)
                return u
            }.value
            guard let self, self.root == rootPath else { return }
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
        // Respect .gitignore for speed; skip ~/Library and Trash (TCC-protected,
        // rarely searched — navigating into one directly indexes it on demand).
        let lines = ExternalTools.run(fd, [
            "--color=never", "--absolute-path", "--type", "f", "--type", "d",
            "--exclude", "Library", "--exclude", ".Trash",
            "--max-results", "\(cap)", ".", path
        ], maxLines: cap, timeout: 20.0)
        return lines.map { URL(fileURLWithPath: $0) }
    }

    // MARK: - Persistence (checkpoint)

    private struct Cached: Codable { let root: String; let paths: [String] }

    private nonisolated static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("anf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fileindex.json")
    }

    nonisolated static func loadCache() -> (root: String, entries: [URL])? {
        guard let data = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(Cached.self, from: data) else { return nil }
        return (c.root, c.paths.map { URL(fileURLWithPath: $0) })
    }

    nonisolated static func saveCache(root: String, entries: [URL]) {
        let c = Cached(root: root, paths: entries.map(\.path))
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: cacheURL) }
    }
}
