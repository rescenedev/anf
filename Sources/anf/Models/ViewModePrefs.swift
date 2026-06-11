import Foundation

/// Per-folder view mode (icons / list / columns / gallery), persisted — folder A
/// can stay a grid of photos while folder B stays a detailed list, like Finder's
/// per-window view memory.
@MainActor
final class ViewModePrefs {
    static let shared = ViewModePrefs()
    private var map: [String: String]
    private let key = "anf.viewmode.byFolder.v1"
    private let cap = 2_000

    private init() {
        map = UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }

    func mode(for url: URL) -> ViewMode? {
        map[url.standardizedFileURL.path].flatMap(ViewMode.init)
    }

    func set(_ mode: ViewMode, for url: URL) {
        map[url.standardizedFileURL.path] = mode.rawValue
        if map.count > cap {   // crude bound; oldest-insertion order isn't tracked
            map.removeValue(forKey: map.keys.first!)
        }
        UserDefaults.standard.set(map, forKey: key)
    }
}
