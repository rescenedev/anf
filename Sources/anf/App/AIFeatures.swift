import Foundation

/// Master switch for the on-device AI features (summarize, ask, suggest name,
/// auto-tag, organize-by-content, image search). Off by default — the AI work
/// (Vision classification, FoundationModels) only runs when the user opts in,
/// via the Tools menu toggle or `"aiFeatures": true` in the ⌘, settings file.
enum AIFeatures {
    private static let key = "anf.aiEnabled"

    /// Emitted when the toggle flips, so open views can refresh.
    static let changed = Notification.Name("anf.aiFeatures.changed")

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set {
            guard newValue != enabled else { return }
            UserDefaults.standard.set(newValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: newValue)
        }
    }
}
