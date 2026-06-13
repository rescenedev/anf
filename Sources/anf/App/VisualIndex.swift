import Foundation

/// Persistent, background image-classification index — the visual counterpart of
/// FileIndex. On-the-fly classification can't scale to a 10k-photo library (a
/// cold search would be tens of seconds), so each image is classified ONCE in
/// the background, its labels stored on disk keyed by path + mtime, and search
/// reads that index instantly with full coverage. Resumable: an image whose
/// mtime already matches is skipped, so reopening a folder is cheap and the
/// first big build survives quits.
///
/// Only classification (cheap, ANE-backed, ~tens of ms) is eagerly indexed.
/// OCR (250ms–1.3s/image) would take hours over 10k images, so image *text*
/// search stays bounded/on-demand in PaletteSearch.
final class VisualIndex: @unchecked Sendable {
    static let shared = VisualIndex()

    private struct Entry: Codable { let mtime: Double; let labels: [String] }

    private let lock = NSLock()
    private var map: [String: Entry] = [:]
    private var building = false
    private var pending: [URL] = []   // roots queued while a build is in flight
    private var saveWork: DispatchWorkItem?

    /// Indexed image count + whether a build is in flight (for a progress hint).
    var status: (indexed: Int, building: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (map.count, building)
    }

    init() { load() }

    // MARK: - Build (background, resumable)

    /// Classify any not-yet-indexed images under `root` in the background.
    /// Cheap to call on every folder change — already-indexed images (matching
    /// mtime) are skipped, and only one build runs at a time.
    func build(for root: URL) {
        guard AIFeatures.enabled else { return }   // no background classification when AI is off
        lock.lock()
        if building {
            // Don't drop it — queue it (deduped) so rapid folder-hopping still
            // gets every folder indexed, just one at a time.
            if !pending.contains(where: { $0.path == root.path }) { pending.append(root) }
            lock.unlock(); return
        }
        building = true
        lock.unlock()
        runBuild(root)
    }

    private func runBuild(_ root: URL) {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                self.scheduleSave()
                self.lock.lock()
                let next = self.pending.isEmpty ? nil : self.pending.removeFirst()
                if next == nil { self.building = false }
                self.lock.unlock()
                if let next { self.runBuild(next) }   // drain the queue
            }

            let images = PaletteSearch.imageFiles(under: root, limit: 100_000)
            // Work the not-yet-current ones in batches, checkpointing per batch
            // so a quit mid-build keeps progress.
            let todo = images.filter { url in
                let path = url.path
                let mtime = Self.mtime(path)
                self.lock.lock(); let cur = self.map[path]; self.lock.unlock()
                return cur == nil || cur!.mtime != mtime
            }
            guard !todo.isEmpty else { return }

            let batchSize = 400
            var i = 0
            while i < todo.count {
                let batch = Array(todo[i ..< min(i + batchSize, todo.count)])
                var results = [(path: String, mtime: Double, labels: [String])]()
                let rlock = NSLock()
                DispatchQueue.concurrentPerform(iterations: batch.count) { k in
                    let url = batch[k]
                    let labels = ImageClassifier.labels(for: url)
                    let row = (url.path, Self.mtime(url.path), labels)
                    rlock.lock(); results.append(row); rlock.unlock()
                }
                self.lock.lock()
                for r in results { self.map[r.path] = Entry(mtime: r.mtime, labels: r.labels) }
                self.lock.unlock()
                self.scheduleSave()
                i += batchSize
            }
        }
    }

    // MARK: - Search (instant)

    /// Image URLs under `root` whose indexed labels match `query`. Reads the
    /// in-memory index — instant, full coverage of whatever's been indexed.
    func search(query: String, root: URL, cap: Int) -> [URL] {
        lock.lock(); let snapshot = map; lock.unlock()
        let base = root.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        var out: [URL] = []
        for (path, e) in snapshot where path.hasPrefix(prefix) {
            if ImageClassifier.matches(query: query, labels: e.labels) {
                out.append(URL(fileURLWithPath: path))
                if out.count >= cap { break }
            }
        }
        return out
    }

    // MARK: - Persistence

    private static func mtime(_ path: String) -> Double {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
    }

    private static var cacheURL: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("anf", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("visualindex.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        lock.lock(); map = decoded; lock.unlock()
    }

    /// Debounced save: a big build checkpoints per batch, so coalesce writes.
    private func scheduleSave() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.saveWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.save() }
            self.saveWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
        }
    }

    private func save() {
        lock.lock(); let snapshot = map; lock.unlock()
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: Self.cacheURL)
            }
        }
    }
}
