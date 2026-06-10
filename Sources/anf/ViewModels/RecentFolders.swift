import Foundation

/// App-wide history of recently visited folders, most-recent-first, persisted to
/// UserDefaults. Feeds the command palette's empty (no-query) state.
@MainActor
final class RecentFolders {
    static let shared = RecentFolders()

    private(set) var items: [URL]
    private let key = "anf.recentFolders.v1"
    private let cap = 40

    private init() {
        let paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        items = paths.map { URL(fileURLWithPath: $0) }
    }

    /// Record a visited folder: move it to the front, dedupe by path, cap length.
    func record(_ url: URL) {
        let std = url.standardizedFileURL
        items.removeAll { $0.standardizedFileURL.path == std.path }
        items.insert(std, at: 0)
        if items.count > cap { items = Array(items.prefix(cap)) }
        UserDefaults.standard.set(items.map(\.path), forKey: key)
    }
}
