import AppKit
import Observation

/// macOS Finder tags (the colour labels), read and written through the same
/// `NSURLTagNamesKey` / `NSURLLabelColorKey` extended attributes Finder uses —
/// so tags set here show up in Finder and vice versa.
enum FileTags {
    /// The seven standard Finder colours, in Finder's order. The name IS the
    /// tag (Finder stores "Red", "빨강" etc. by the system language); we use the
    /// English canonical names so they interoperate with Finder.
    static let standard: [(name: String, color: NSColor)] = [
        ("Red", .systemRed), ("Orange", .systemOrange), ("Yellow", .systemYellow),
        ("Green", .systemGreen), ("Blue", .systemBlue), ("Purple", .systemPurple),
        ("Gray", .systemGray),
    ]

    static func color(for tag: String) -> NSColor? {
        standard.first { $0.name == tag }?.color
    }

    /// Current tag names on a file.
    static func tags(of url: URL) -> [String] {
        (try? url.resourceValues(forKeys: [.tagNamesKey]))?.tagNames ?? []
    }

    /// Replace the file's tags wholesale. The typed `URLResourceValues.tagNames`
    /// SETTER is macOS 26-only; the NSURL spelling writes the same
    /// NSURLTagNamesKey xattr and works on every macOS we support.
    static func setTags(_ tags: [String], on url: URL) {
        try? (url as NSURL).setResourceValue(tags as NSArray, forKey: .tagNamesKey)
    }

    /// Toggle one standard colour tag on/off. `setTags` makes a synchronous
    /// DesktopServices/Spotlight XPC round-trip, so callers toggling a SELECTION
    /// must run this OFF the main thread (it otherwise beachballs the UI). Pass
    /// `reindex: false` for a batch and call `reindex(allURLs)` once at the end,
    /// instead of spawning one `mdimport` process per file.
    static func toggle(_ tag: String, on url: URL, reindex doReindex: Bool = true) {
        var current = tags(of: url)
        if let i = current.firstIndex(of: tag) { current.remove(at: i) }
        else { current.append(tag) }
        setTags(current, on: url)
        if doReindex { reindex([url]) }   // reflect in Finder/Spotlight immediately
    }

    // Per-listing tag cache: the list draws per row on every scroll frame, and a
    // getxattr per cell adds up. Cached by path, cleared on reload (tag edits
    // reload, so they stay fresh).
    //
    // The cache is fed ASYNCHRONOUSLY: `display` never reads the file system.
    // It used to do the read inline on a miss — but display runs per row inside
    // cell drawing on the MAIN thread, and the read is a getxattr that
    // round-trips the network on SMB/NFS. Scrolling a big NAS folder (every
    // reload clears this cache) was hundreds of sequential blocking round-trips
    // on the main thread — a beachball reported on photo-heavy NAS browsing.
    @MainActor private static var tagCache: [String: (color: NSColor?, named: [String])] = [:]
    @MainActor private static var pending: Set<String> = []
    @MainActor private static var fetchQueue: [URL] = []
    /// Bumped by clearColorCache so an in-flight batch from BEFORE the clear
    /// (its reads may predate the tag edit that caused the clear) is discarded.
    @MainActor private static var generation = 0

    /// Posted (coalesced, once per resolved batch) after tag reads land — the
    /// AppKit views refresh their visible rows on it.
    static let tagsResolvedNote = Notification.Name("anf.tagsResolved")

    /// Test seam: replaces the on-disk xattr read so the async pipeline is
    /// testable without touching the metadata daemon (see ANF_SKIP_TAGS).
    nonisolated(unsafe) static var readOverride: (@Sendable (URL) -> [String])?

    @MainActor static func clearColorCache() {
        tagCache.removeAll(keepingCapacity: true)
        pending.removeAll()
        fetchQueue.removeAll()
        generation &+= 1
    }

    /// Cached (primary colour, named tags) for a file. Named tags are those
    /// without a standard colour — topic tags like "invoice", "art".
    /// NEVER reads the file system: a miss returns "untagged" immediately and
    /// queues a background read; when the batch lands, `tagsResolvedNote` fires
    /// and `TagVersion` bumps so both AppKit rows and SwiftUI readers repaint.
    @MainActor static func display(of url: URL) -> (color: NSColor?, named: [String]) {
        if let hit = tagCache[url.path] { return hit }
        enqueueFetch(url)
        return (nil, [])
    }

    /// The first standard colour among a file's tags (for the row swatch).
    @MainActor static func primaryColor(of url: URL) -> NSColor? { display(of: url).color }

    @MainActor private static func enqueueFetch(_ url: URL) {
        guard pending.insert(url.path).inserted else { return }
        fetchQueue.append(url)
        guard fetchQueue.count == 1 else { return }   // a drain is already armed
        let gen = generation
        Task { @MainActor in
            // Let the scroll burst accumulate, then read the whole batch off-main.
            try? await Task.sleep(nanoseconds: 30_000_000)
            while !fetchQueue.isEmpty, generation == gen {
                let batch = fetchQueue
                fetchQueue.removeAll()
                let read = readOverride
                let results = await Task.detached(priority: .userInitiated) {
                    () -> [(String, [String])] in
                    batch.map { ($0.path, read?($0) ?? tags(of: $0)) }
                }.value
                guard generation == gen else { return }   // cleared mid-flight → stale
                var resolved = Set<String>()
                for (path, ts) in results {
                    var color: NSColor?
                    var named: [String] = []
                    for t in ts {
                        if let c = Self.color(for: t) { if color == nil { color = c } }
                        else { named.append(t) }
                    }
                    tagCache[path] = (color, named)
                    pending.remove(path)
                    resolved.insert(path)
                }
                TagVersion.shared.bump()
                NotificationCenter.default.post(name: tagsResolvedNote, object: nil,
                                                userInfo: ["paths": resolved])
            }
        }
    }

    /// Force Spotlight to re-read the tags so they show up in Finder (its Tags
    /// sidebar/column and search) without waiting for the next index pass.
    /// Writing the xattr alone often doesn't trigger reindex; `mdimport` does.
    /// Fire-and-forget, off the main thread, chunked to keep the arg list sane.
    nonisolated static func reindex(_ urls: [URL]) {
        let paths = urls.map(\.path)
        guard !paths.isEmpty else { return }
        Task.detached(priority: .utility) {
            for chunk in stride(from: 0, to: paths.count, by: 200).map({ Array(paths[$0..<min($0 + 200, paths.count)]) }) {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
                p.arguments = chunk
                try? p.run()
                p.waitUntilExit()
            }
        }
    }
}

/// Observable counter bumped when a tag batch resolves — SwiftUI tag readers
/// (the column view's rows) read `n` in `body` to subscribe, since the tag
/// cache itself is plain static storage the Observation runtime can't see.
@MainActor
@Observable
final class TagVersion {
    static let shared = TagVersion()
    private(set) var n = 0
    fileprivate func bump() { n &+= 1 }
}
