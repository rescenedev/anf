import Foundation

/// Image classification labels keyed by path + mtime. Mirrors OCRTextCache.
/// Classification is cheap (tens of ms) but still worth caching so repeated
/// queries over the same folder don't reclassify every image per keystroke.
final class ImageLabelCache: @unchecked Sendable {
    static let shared = ImageLabelCache()

    private let cond = NSCondition()
    private var map: [String: (mtime: Date, labels: [String])] = [:]
    private var lru: [String] = []
    private var inFlight: Set<String> = []
    private let cap = 2048   // labels are tiny

    func labels(for url: URL) -> [String] {
        let path = url.path

        cond.lock()
        while inFlight.contains(path) { cond.wait() }
        // Read mtime while holding the lock so the cache key is consistent with
        // what was current at the moment of the lookup. Reading it before locking
        // created a TOCTOU window: a file modified between the stat and lock
        // acquisition would compare against a stale mtime and return stale labels
        // (ILC-001). The stat itself is fast; the classification (below) stays
        // outside the lock where it belongs.
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date ?? .distantPast
        if let hit = map[path], hit.mtime == mtime {
            lru.removeAll { $0 == path }; lru.append(path)
            let labels = hit.labels
            cond.unlock()
            return labels
        }
        inFlight.insert(path)
        cond.unlock()

        let computed = ImageClassifier.labels(for: url)

        cond.lock()
        // Re-stat before storing so the cached mtime reflects the file state at
        // the END of classification, not the start. If the file changed during
        // classification the stored mtime will be T2, and the next lookup (which
        // will also read T2) will miss the stale entry and reclassify correctly.
        let storedMtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date ?? mtime
        map[path] = (storedMtime, computed)
        lru.removeAll { $0 == path }; lru.append(path)
        while lru.count > cap { map.removeValue(forKey: lru.removeFirst()) }
        inFlight.remove(path)
        cond.broadcast()
        cond.unlock()
        return computed
    }
}
