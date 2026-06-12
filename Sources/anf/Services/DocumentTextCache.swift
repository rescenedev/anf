import Foundation

/// Extracted document bodies (path + mtime keyed), shared by the palette's
/// content search and the inspector preview. Without it every keystroke in the
/// palette re-extracted every PDF/office file in scope — typing a 4-character
/// query meant 4 full extraction sweeps. With it only the first sweep pays;
/// the rest match against cached text in microseconds.
final class DocumentTextCache: @unchecked Sendable {
    static let shared = DocumentTextCache()

    private let lock = NSLock()
    private var map: [String: (mtime: Date, text: String)] = [:]
    private var lru: [String] = []   // most recently used last
    private let cap = 256            // files; bodies are tens of KB each

    /// Cached body text, extracting (and caching — including empty results,
    /// so unextractable files aren't retried) on miss. Safe to call from
    /// concurrent sweeps.
    func text(for url: URL) -> String? {
        let path = url.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date ?? .distantPast

        lock.lock()
        if let hit = map[path], hit.mtime == mtime {
            lru.removeAll { $0 == path }
            lru.append(path)
            let text = hit.text
            lock.unlock()
            return text.isEmpty ? nil : text
        }
        lock.unlock()

        let extracted = DocumentText.extract(url) ?? ""

        lock.lock()
        map[path] = (mtime, extracted)
        lru.removeAll { $0 == path }
        lru.append(path)
        while lru.count > cap {
            map.removeValue(forKey: lru.removeFirst())
        }
        lock.unlock()
        return extracted.isEmpty ? nil : extracted
    }
}
