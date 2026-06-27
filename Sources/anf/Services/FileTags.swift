import AppKit

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
    @MainActor private static var tagCache: [String: (color: NSColor?, named: [String])] = [:]

    @MainActor static func clearColorCache() { tagCache.removeAll(keepingCapacity: true) }

    /// Cached (primary colour, named tags) for a file. Named tags are those
    /// without a standard colour — topic tags like "invoice", "art".
    @MainActor static func display(of url: URL) -> (color: NSColor?, named: [String]) {
        if let hit = tagCache[url.path] { return hit }
        var color: NSColor?
        var named: [String] = []
        for t in tags(of: url) {
            if let c = Self.color(for: t) { if color == nil { color = c } }
            else { named.append(t) }
        }
        let result = (color, named)
        tagCache[url.path] = result
        return result
    }

    /// The first standard colour among a file's tags (for the row swatch).
    @MainActor static func primaryColor(of url: URL) -> NSColor? { display(of: url).color }

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
