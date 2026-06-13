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
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date ?? .distantPast

        cond.lock()
        while inFlight.contains(path) { cond.wait() }
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
        map[path] = (mtime, computed)
        lru.removeAll { $0 == path }; lru.append(path)
        while lru.count > cap { map.removeValue(forKey: lru.removeFirst()) }
        inFlight.remove(path)
        cond.broadcast()
        cond.unlock()
        return computed
    }
}
