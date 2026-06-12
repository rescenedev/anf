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

    /// Replace the file's tags wholesale.
    static func setTags(_ tags: [String], on url: URL) {
        var u = url
        var v = URLResourceValues()
        v.tagNames = tags
        try? u.setResourceValues(v)
    }

    /// Toggle one standard colour tag on/off.
    static func toggle(_ tag: String, on url: URL) {
        var current = tags(of: url)
        if let i = current.firstIndex(of: tag) { current.remove(at: i) }
        else { current.append(tag) }
        setTags(current, on: url)
    }

    // Per-listing colour cache: the list draws a swatch per visible row on
    // every scroll frame, and a getxattr per cell adds up. Cached by path,
    // cleared on reload (toggleTag reloads, so edits stay fresh).
    @MainActor private static var colorCache: [String: NSColor?] = [:]

    @MainActor static func clearColorCache() { colorCache.removeAll(keepingCapacity: true) }

    /// The first standard colour among a file's tags (for the row swatch).
    @MainActor static func primaryColor(of url: URL) -> NSColor? {
        if let hit = colorCache[url.path] { return hit }
        var found: NSColor?
        for t in tags(of: url) where color(for: t) != nil { found = color(for: t); break }
        colorCache[url.path] = found
        return found
    }
}
