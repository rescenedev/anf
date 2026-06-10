import Foundation
import CoreServices

/// Background filename index for the focused folder, persisted to disk so it
/// survives quit/relaunch, and kept live with FSEvents so add/remove/rename are
/// applied incrementally (no full rescan). On launch the last checkpoint loads
/// instantly; the palette fuzzy-filters the in-memory list per keystroke. Without
/// `fd` there's no index and the palette falls back to mdfind / FileManager.
@MainActor
final class FileIndex {
    static let shared = FileIndex()

    private(set) var root: String?
    private(set) var entries: [URL] = []
    private(set) var ready = false

    private var pathSet: Set<String> = []
    private var task: Task<Void, Never>?
    private var seeded = false
    private var lastScan: [String: Date] = [:]
    private var stream: FSEventStreamRef?
    private var saveWork: DispatchWorkItem?

    /// Ensure `url` (and below) is indexed. Reuses a broader in-memory or on-disk
    /// index that already covers it; otherwise (re)builds rooted at `url`.
    func build(for url: URL) {
        guard ExternalTools.path("fd") != nil else { reset(); return }
        let path = url.standardizedFileURL.path

        if !seeded {
            seeded = true
            if let c = Self.loadCache() {
                root = c.root; entries = c.entries; pathSet = Set(c.entries.map(\.path)); ready = true
                startWatching(c.root)
            }
        }

        if let r = root, ready, Self.isUnder(path, r) {
            return                                   // covered; FSEvents keeps it fresh
        }
        root = path; entries = []; pathSet = []; ready = false
        refresh(path, force: true)
    }

    private func reset() { stopWatching(); task?.cancel(); root = nil; ready = false; entries = []; pathSet = [] }

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
            self.pathSet = Set(urls.map(\.path))
            self.ready = true
            self.startWatching(rootPath)
        }
    }

    // MARK: - Incremental updates (FSEvents)

    private func startWatching(_ rootPath: String) {
        stopWatching()
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot)
        let cb: FSEventStreamCallback = { _, info, num, paths, eventFlags, _ in
            guard let info else { return }
            let me = Unmanaged<FileIndex>.fromOpaque(info).takeUnretainedValue()
            let cpaths = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            let fl = (0..<num).map { eventFlags[$0] }
            Task { @MainActor in me.apply(paths: cpaths, flags: fl) }
        }
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, cb, &ctx,
                                          [rootPath] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.4, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    private func stopWatching() {
        guard let s = stream else { return }
        FSEventStreamStop(s); FSEventStreamInvalidate(s); FSEventStreamRelease(s)
        stream = nil
    }

    private func apply(paths: [String], flags: [FSEventStreamEventFlags]) {
        guard let root, ready else { return }
        let fm = FileManager.default
        var changed = false
        for (i, p) in paths.enumerated() {
            guard Self.isUnder(p, root) else { continue }
            if p.contains("/Library/") || p.contains("/.Trash") { continue }
            // A coalesced "must rescan" event → safest to do a throttled full rescan.
            if flags[i] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                refresh(root); return
            }
            if fm.fileExists(atPath: p) {
                if pathSet.insert(p).inserted { entries.append(URL(fileURLWithPath: p)); changed = true }
            } else {
                // Removed/renamed-away: drop the path and any descendants.
                let prefix = p.hasSuffix("/") ? p : p + "/"
                let before = entries.count
                entries.removeAll { $0.path == p || $0.path.hasPrefix(prefix) }
                if entries.count != before {
                    pathSet = Set(entries.map(\.path)); changed = true
                }
            }
        }
        if changed { scheduleSave() }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = entries
        let r = root
        let work = DispatchWorkItem { if let r { FileIndex.saveCache(root: r, entries: snapshot) } }
        saveWork = work
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Queries

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
