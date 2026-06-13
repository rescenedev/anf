import Foundation

/// OCR results keyed by path + mtime, shared by content search and (later) the
/// inspector. Mirrors DocumentTextCache: OCR is far heavier than unzip (hundreds
/// of ms per image), so caching matters even more — without it every keystroke
/// in the palette would re-OCR every image in scope. Overlapping sweeps for the
/// same file wait on the first instead of duplicating the work.
final class OCRTextCache: @unchecked Sendable {
    static let shared = OCRTextCache()

    private let cond = NSCondition()
    private var map: [String: (mtime: Date, text: String)] = [:]
    private var lru: [String] = []
    private var inFlight: Set<String> = []
    private let cap = 512   // OCR text is small; keep plenty cached

    /// Cached OCR text, recognizing (and caching, including empty results) on
    /// miss. Empty is cached too so text-free images aren't re-OCR'd forever.
    func text(for url: URL) -> String? {
        let path = url.path
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate]
            as? Date ?? .distantPast

        cond.lock()
        while inFlight.contains(path) { cond.wait() }
        if let hit = map[path], hit.mtime == mtime {
            lru.removeAll { $0 == path }
            lru.append(path)
            let text = hit.text
            cond.unlock()
            return text.isEmpty ? nil : text
        }
        inFlight.insert(path)
        cond.unlock()

        let recognized = OCRService.recognizeText(in: url) ?? ""

        cond.lock()
        map[path] = (mtime, recognized)
        lru.removeAll { $0 == path }
        lru.append(path)
        while lru.count > cap { map.removeValue(forKey: lru.removeFirst()) }
        inFlight.remove(path)
        cond.broadcast()
        cond.unlock()
        return recognized.isEmpty ? nil : recognized
    }

    /// Already cached (any mtime)? Lets callers prefer cheap hits without
    /// blocking on a cold OCR pass.
    func cached(for url: URL) -> String? {
        cond.lock(); defer { cond.unlock() }
        return map[url.path]?.text
    }
}
