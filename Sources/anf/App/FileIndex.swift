import Foundation
import CoreServices

/// Background filename index for the focused folder, persisted to disk so it
/// survives quit/relaunch, and kept fresh with FSEvents. On any change under the
/// indexed root a **debounced background rescan** runs (off the main thread) — so
/// even a busy tree never hitches the UI. On launch the last checkpoint loads
/// instantly; the palette fuzzy-filters the in-memory list off-main per search.
/// Without `fd` there's no index and the palette falls back to mdfind/FileManager.
@MainActor
final class FileIndex {
    static let shared = FileIndex()

    private(set) var root: String?
    private(set) var entries: [URL] = []
    private(set) var ready = false

    private var task: Task<Void, Never>?
    private var seeded = false
    private var lastScan: [String: Date] = [:]
    private var stream: FSEventStreamRef?
    private var rescanWork: DispatchWorkItem?
    private var saveWork: DispatchWorkItem?

    /// Ensure `url` (and below) is indexed. Reuses a broader in-memory or on-disk
    /// index that already covers it; otherwise (re)builds rooted at `url`.
    func build(for url: URL) {
        guard ExternalTools.path("fd") != nil else { reset(); return }
        let path = url.standardizedFileURL.path

        if !seeded {
            seeded = true
            if let c = Self.loadCache() {
                root = c.root; entries = c.entries; ready = true
                startWatching(c.root)
            }
        }

        if let r = root, ready, Self.isUnder(path, r) { return }   // covered; FSEvents keeps it fresh
        root = path; entries = []; ready = false
        refresh(path, force: true)
    }

    private func reset() { stopWatching(); task?.cancel(); root = nil; ready = false; entries = [] }

    /// Full (re)scan of `rootPath` in the background; replaces entries, re-saves
    /// the checkpoint and (re)starts the FSEvents watcher. Throttled.
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
            self.startWatching(rootPath)
        }
    }

    // MARK: - FSEvents (debounced background rescan)

    private func startWatching(_ rootPath: String) {
        stopWatching()
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        // UseCFTypes is REQUIRED: without it eventPaths is a C char** array and
        // bit-casting it to NSArray crashes when a change fires.
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot
                           | kFSEventStreamCreateFlagUseCFTypes)
        let cb: FSEventStreamCallback = { _, info, num, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileIndex>.fromOpaque(info).takeUnretainedValue()
            let cpaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            Task { @MainActor in me.onChange(cpaths) }
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx,
                                          [rootPath] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          1.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    private func stopWatching() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    /// A change under the root → schedule a debounced full rescan off-main. The
    /// debounce coalesces bursts, so an actively-churning tree never rescans (or
    /// hitches) until it settles. Noisy build/vcs paths are ignored.
    private func onChange(_ paths: [String]) {
        guard let root, ready else { return }
        let relevant = paths.contains { p in
            Self.isUnder(p, root)
                && !p.contains("/Library/") && !p.contains("/.Trash")
                && !p.contains("/node_modules/") && !p.contains("/.git/")
                && !p.contains("/target/") && !p.contains("/.build/") && !p.contains("/build/")
        }
        guard relevant else { return }
        rescanWork?.cancel()
        let r = root
        let work = DispatchWorkItem { [weak self] in self?.refresh(r, force: true) }
        rescanWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    // MARK: - Queries

    /// Full indexed entries if they cover `url` (cheap COW; caller filters off the
    /// main thread). nil when not covered/ready.
    func entriesIfCovers(_ url: URL) -> [URL]? {
        let path = url.standardizedFileURL.path
        guard ready, let root, Self.isUnder(path, root) else { return nil }
        return entries
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

    nonisolated static func isUnder(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    nonisolated private static func scan(path: String) -> [URL] {
        let cap = 300_000
        guard let fd = ExternalTools.path("fd") else { return [] }
        let lines = ExternalTools.run(fd, [
            "--color=never", "--absolute-path", "--type", "f", "--type", "d",
            "--exclude", "Library", "--exclude", ".Trash",
            "--exclude", "node_modules", "--exclude", ".git",
            "--exclude", "target", "--exclude", ".build", "--exclude", "build",
            "--exclude", "dist", "--exclude", ".venv", "--exclude", "Pods",
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
