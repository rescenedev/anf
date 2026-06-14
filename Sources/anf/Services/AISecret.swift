import Foundation

/// The Anthropic API key, kept in the macOS Keychain (see `Keychain`). This is
/// the single source of truth for both `ClaudeLLM` and `RemoteLLM`. The settings
/// file and UserDefaults NEVER hold the key — older builds did, so `migrate()`
/// moves any leftover plaintext into the Keychain and scrubs it on launch.
enum AISecret {
    static let account = "aiApiKey"
    private static let legacyDefaultsKey = "anf.aiApiKey"

    // Cached so menu validation / `isConfigured` checks don't hit the keychain on
    // every call. `.none` = not loaded yet; `.some(nil)` = loaded, no key. Guarded
    // by `lock` because `key` is read from the main actor (menus) AND background
    // tasks (ClaudeLLM/RemoteLLM network calls run nonisolated) — a data race
    // otherwise.
    private static let lock = NSLock()
    private static var cache: String?? = .none

    #if DEBUG
    /// Test seam: when active, bypasses the Keychain so unit tests never touch it
    /// (and never risk a headless keychain prompt). `.none` = inactive.
    nonisolated(unsafe) static var testOverride: String?? = .none
    #endif

    /// The current key, or nil if none is set.
    static var key: String? {
        #if DEBUG
        if case let .some(v) = testOverride { return v }
        #endif
        lock.lock(); defer { lock.unlock() }
        if case let .some(v) = cache { return v }
        let v = Keychain.get(account)
        cache = .some(v)
        return v
    }

    /// Store (or clear, when nil/blank) the key in the Keychain.
    @discardableResult
    static func setKey(_ value: String?) -> Bool {
        let ok = Keychain.set(account, value)
        let refreshed = Keychain.get(account)
        lock.lock(); cache = .some(refreshed); lock.unlock()
        return ok
    }

    static var hasKey: Bool { key != nil }

    /// Move a key left in the old plaintext locations (UserDefaults mirror and the
    /// settings JSON) into the Keychain, then erase the plaintext. Idempotent and
    /// cheap when there's nothing to migrate. Settings-file scrub is regex-based so
    /// it survives the user's own formatting.
    @MainActor
    static func migrate(settingsFile: URL) {
        let defaults = UserDefaults.standard
        // 1) UserDefaults mirror (older builds copied the key here).
        if let fromDefaults = defaults.string(forKey: legacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !fromDefaults.isEmpty {
            if !hasKey { setKey(fromDefaults) }
            defaults.removeObject(forKey: legacyDefaultsKey)
        }
        // 2) The settings file itself.
        guard let text = try? String(contentsOf: settingsFile, encoding: .utf8) else { return }
        if let value = jsonStringValue(of: "aiApiKey", in: text), !value.isEmpty {
            if !hasKey { setKey(value) }
            let scrubbed = scrub(key: "aiApiKey", in: text)
            if scrubbed != text { try? scrubbed.write(to: settingsFile, atomically: true, encoding: .utf8) }
        }
    }

    /// Pull `"<key>": "<value>"` out of raw JSON text (nil if absent/non-string).
    static func jsonStringValue(of key: String, in text: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: "\"\(key)\"\\s*:\\s*\"([^\"]*)\"") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = re.firstMatch(in: text, range: range), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    /// Replace `"<key>": "<anything>"` with an empty value, in place.
    static func scrub(key: String, in text: String) -> String {
        guard let re = try? NSRegularExpression(pattern: "(\"\(key)\"\\s*:\\s*\")[^\"]*(\")") else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, range: range, withTemplate: "$1$2")
    }
}
