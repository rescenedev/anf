import Foundation

/// Serializable snapshot of a window arrangement — the pane layout, split ratios
/// and each pane's tabs — so a "view" can be saved and recalled on demand.
struct ViewSnapshot: Codable, Hashable {
    struct Tab: Codable, Hashable { var path: String; var viewMode: String }
    struct Pane: Codable, Hashable { var tabs: [Tab]; var activeIndex: Int }
    var layout: String
    var activePane: Int
    var splitRatioH: Double
    var splitRatioV: Double
    var panes: [Pane]
}

/// A named, recallable window arrangement.
struct SavedView: Codable, Identifiable, Hashable {
    let id: UUID
    var name: String
    var snapshot: ViewSnapshot

    init(id: UUID = UUID(), name: String, snapshot: ViewSnapshot) {
        self.id = id
        self.name = name
        self.snapshot = snapshot
    }
}

/// User-saved views, persisted to UserDefaults so they survive relaunch.
@MainActor
@Observable
final class SavedViewsStore {
    /// Shared across all windows (see FavoritesStore.shared) so per-window
    /// instances can't go stale or overwrite each other's saved views.
    static let shared = SavedViewsStore()

    private static let key = "anf.savedViews.v1"
    private(set) var views: [SavedView]

    private static let importedKey = "anf.savedViews.importedIds"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let decoded = try? JSONDecoder().decode([SavedView].self, from: data) {
            views = decoded
        } else {
            views = []
        }
        importFromSettings()
    }

    /// Import `"workspaces": [ {SavedView JSON} ]` from the ⌘, settings file —
    /// for migrating saved window arrangements to a new Mac. Each id is imported
    /// once (tracked), so removing one in-app won't resurrect it.
    private func importFromSettings() {
        guard let raw = Keymap.settingsDict(fileAt: Keymap.fileURL)["workspaces"],
              let data = try? JSONSerialization.data(withJSONObject: raw),
              let decoded = try? JSONDecoder().decode([SavedView].self, from: data) else { return }
        var imported = Set(UserDefaults.standard.stringArray(forKey: Self.importedKey) ?? [])
        var changed = false, importedChanged = false
        for v in decoded {
            let key = v.id.uuidString
            guard !imported.contains(key) else { continue }
            imported.insert(key); importedChanged = true
            if !views.contains(where: { $0.id == v.id }) { views.append(v); changed = true }
        }
        if importedChanged { UserDefaults.standard.set(Array(imported), forKey: Self.importedKey) }
        if changed { persist() }
    }

    /// JSON for the current views, to paste into the settings file's "workspaces".
    func exportJSON() -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(views)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
    }

    func add(_ view: SavedView) { views.append(view); persist() }

    func remove(id: UUID) { views.removeAll { $0.id == id }; persist() }

    func rename(id: UUID, to name: String) {
        guard let i = views.firstIndex(where: { $0.id == id }) else { return }
        views[i].name = name
        persist()
    }

    /// Overwrite an existing view's arrangement with a fresh snapshot.
    func update(id: UUID, snapshot: ViewSnapshot) {
        guard let i = views.firstIndex(where: { $0.id == id }) else { return }
        views[i].snapshot = snapshot
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(views) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
