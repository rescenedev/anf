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
    /// Absolute paths, as scanned. Strings, not URLs: building 124k+ `URL`s cost
    /// ~770ms per (re)scan/cache-load and they were only ever needed for the top
    /// hits — callers materialise URLs for results only.
    private(set) var paths: [String] = []
    /// Pre-normalized (NFC + lowercased) path per entry, parallel to `paths`, so
    /// per-keystroke fuzzy ranking never lowercases the pool again.
    private(set) var lowerPaths: [String] = []
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
            // Decode the checkpoint OFF-main: it can hold 300k paths and JSON
            // decoding that synchronously was a visible hitch on first ⌘K.
            Task { [weak self] in
                guard let c = await Task.detached(priority: .userInitiated, operation: {
                    Self.loadCache()
                }).value else { return }
                guard let self, self.root == nil || self.root == c.root else { return }
                if self.ready { return }   // a live scan finished first
                self.root = c.root
                self.paths = c.paths
                self.lowerPaths = c.lower
                self.ready = true
                self.generation &+= 1
                self.startWatching(c.root)
            }
        }

        if let r = root, Self.isUnder(path, r) {
            if ready { return }        // covered & fresh; FSEvents keeps it so
            // Covered by a scan that's still RUNNING. Returning here is critical:
            // build() fires on every interaction (onActivity), and restarting the
            // fd scan each time meant it never finished — and each (re)completion
            // re-normalized + re-serialized the whole index, pegging a core while
            // the app sat idle.
            if task != nil { return }
        }
        root = path; paths = []; lowerPaths = []; ready = false; generation &+= 1
        refresh(path, force: true)
    }

    private func reset() {
        stopWatching(); task?.cancel()
        root = nil; ready = false; paths = []; lowerPaths = []; generation &+= 1
    }

    /// Full (re)scan of `rootPath` in the background; replaces entries, re-saves
    /// the checkpoint and (re)starts the FSEvents watcher. Throttled.
    private func refresh(_ rootPath: String, force: Bool = false) {
        if !force, let last = lastScan[rootPath], Date().timeIntervalSince(last) < 20 { return }
        lastScan[rootPath] = Date()
        task?.cancel()
        task = Task { [weak self] in
            let scanned = await Task.detached(priority: .utility) { () -> (paths: [String], lower: [String]) in
                let u = FileIndex.scan(path: rootPath)
                FileIndex.saveCache(root: rootPath, paths: u.paths)
                return u
            }.value
            guard let self else { return }
            self.task = nil            // in-flight marker for build()'s guard
            guard self.root == rootPath else { return }
            self.paths = scanned.paths
            self.lowerPaths = scanned.lower
            self.generation &+= 1
            self.ready = true
            self.startWatching(rootPath)
        }
    }

    // MARK: - FSEvents (debounced background rescan)

    private func startWatching(_ rootPath: String) {
        stopWatching()
        // CRITICAL: FSEventStreamCreate opens the watched path. On a hung mount
        // (an asleep SMB/NFS NAS) that open() blocks for the network timeout —
        // tens of seconds — so it must NOT run on the main thread, or the whole
        // UI beachballs. Create the stream on a background queue and hand it back.
        let info = Unmanaged.passUnretained(self).toOpaque()
        let flags = UInt32(kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot
                           | kFSEventStreamCreateFlagUseCFTypes)
        let cb: FSEventStreamCallback = { _, info, num, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FileIndex>.fromOpaque(info).takeUnretainedValue()
            let cpaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            Task { @MainActor in me.onChange(cpaths) }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var ctx = FSEventStreamContext(version: 0, info: info,
                                           retain: nil, release: nil, copyDescription: nil)
            guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx,
                                              [rootPath] as CFArray,
                                              FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                              1.0, flags) else { return }
            FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(s)
            Task { @MainActor in
                guard let self else {
                    FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s); return
                }
                // A newer watch may have started while we were blocked — keep the
                // newest, tear this one down.
                if self.stream != nil {
                    FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
                } else {
                    self.stream = s
                }
            }
        }
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

    /// Search pool (paths + pre-normalized paths, parallel arrays) if the index
    /// covers `url`. Cheap COW handoff; the caller filters/ranks off-main and
    /// materialises URLs only for its hits.
    func poolIfCovers(_ url: URL) -> (paths: [String], lower: [String])? {
        let path = url.standardizedFileURL.path
        guard ready, let root, Self.isUnder(path, root),
              paths.count == lowerPaths.count else { return nil }
        return (paths, lowerPaths)
    }

    /// Indexed paths scoped to `url` (and below), or nil if not covered/ready.
    func snapshot(for url: URL) -> [String]? {
        let path = url.standardizedFileURL.path
        guard ready, let root, Self.isUnder(path, root) else { return nil }
        if path == root { return paths }
        return paths.filter { Self.isUnder($0, path) }
    }

    /// Cache for `directories(for:)` — without it every (debounced) keystroke's
    /// search start re-filters up to 300k entries on the MAIN thread just to feed
    /// the scan-ticker animation.
    private var dirsCache: (path: String, generation: Int, dirs: [String])?
    private var generation = 0   // bumped whenever `entries` is replaced

    /// Distinct directory paths under `url` — for the scanning animation.
    func directories(for url: URL, limit: Int = 400) -> [String] {
        let path = url.standardizedFileURL.path
        if let c = dirsCache, c.path == path, c.generation == generation { return c.dirs }
        guard let snap = snapshot(for: url) else { return [] }
        var seen = Set<String>()
        var dirs: [String] = []
        for e in snap {
            let d = (e as NSString).deletingLastPathComponent
            if seen.insert(d).inserted { dirs.append(d); if dirs.count >= limit { break } }
        }
        dirsCache = (path, generation, dirs)
        return dirs
    }

    nonisolated static func isUnder(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    nonisolated private static func scan(path: String) -> (paths: [String], lower: [String]) {
        let cap = 300_000
        guard let fd = ExternalTools.path("fd") else { return ([], []) }
        let lines = ExternalTools.run(fd, [
            "--color=never", "--absolute-path", "--type", "f", "--type", "d",
            "--exclude", "Library", "--exclude", ".Trash",
            "--exclude", "node_modules", "--exclude", ".git",
            "--exclude", "target", "--exclude", ".build", "--exclude", "build",
            "--exclude", "dist", "--exclude", ".venv", "--exclude", "Pods",
            "--max-results", "\(cap)", ".", path
        ], maxLines: cap, timeout: 20.0)
        // Share storage when normalization is a no-op (most ASCII paths): the
        // lowered array then references the same String buffers instead of
        // doubling index memory.
        return (lines, lines.map { p in
            let l = FuzzyMatch.normalizeForIndex(p); return l == p ? p : l
        })
    }

    // MARK: - Persistence (checkpoint)

    private struct Cached: Codable { let root: String; let paths: [String] }

    private nonisolated static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("anf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("fileindex.json")
    }

    nonisolated static func loadCache() -> (root: String, paths: [String], lower: [String])? {
        guard let data = try? Data(contentsOf: cacheURL),
              let c = try? JSONDecoder().decode(Cached.self, from: data) else { return nil }
        return (c.root, c.paths, c.paths.map { p in
            let l = FuzzyMatch.normalizeForIndex(p); return l == p ? p : l
        })
    }

    nonisolated static func saveCache(root: String, paths: [String]) {
        let c = Cached(root: root, paths: paths)
        if let data = try? JSONEncoder().encode(c) { try? data.write(to: cacheURL) }
    }
}
