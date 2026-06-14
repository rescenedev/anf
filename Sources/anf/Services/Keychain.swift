import Foundation
import Security

/// Thin wrapper over macOS Keychain Services for storing secrets (the Anthropic
/// API key). Secrets live ONLY here — never in the settings file or UserDefaults,
/// which are plaintext on disk. One generic-password item per `account` under
/// anf's service identifier, in the user's login keychain.
enum Keychain {
    private static let service = "com.anf.finder"

    /// The stored secret for `account`, or nil if absent/empty.
    static func get(_ account: String) -> String? {
        var q = baseQuery(account)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    /// Store the secret (updating in place if it already exists). A nil/blank
    /// value deletes the item instead. Returns whether the keychain accepted it.
    @discardableResult
    static func set(_ account: String, _ value: String?) -> Bool {
        let trimmed = (value ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete(account) }
        let data = Data(trimmed.utf8)
        let update = SecItemUpdate(baseQuery(account) as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        guard update == errSecItemNotFound else { return false }
        var add = baseQuery(account)
        add[kSecValueData as String] = data
        // Readable whenever the Mac has been unlocked once since boot — enough for
        // a background AI request, never synced off the device.
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    static func delete(_ account: String) -> Bool {
        let status = SecItemDelete(baseQuery(account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
}
