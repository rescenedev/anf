import Foundation

/// UI language follows the OS. Korean and English live as paired literals in
/// code (grep-able, and safe for interpolated strings); ADDITIONAL languages
/// are plain `.strings` tables keyed by the English string — drop
/// `Resources/l10n/<code>.strings` in and rebuild, no code changes. Static
/// strings translate via the table; interpolated ones fall back to English.
/// The template (all 170+ keys with Korean reference values) is regenerated
/// by `tools/gen-l10n.py` and checked in CI.
enum L10n {
    static let isKorean: Bool =
        Locale.preferredLanguages.first?.hasPrefix("ko") ?? false

    /// english → translation for the best-matching bundled language, or nil
    /// when the user's languages are ko/en (which ship in code).
    static let table: [String: String]? = loadTable()

    private static func loadTable() -> [String: String]? {
        for lang in Locale.preferredLanguages {
            let code = String(lang.prefix(2))
            if code == "en" || code == "ko" { return nil }   // in-code languages
            if let url = Bundle.module.url(forResource: code, withExtension: "strings",
                                           subdirectory: "l10n"),
               let dict = NSDictionary(contentsOf: url) as? [String: String] {
                return dict
            }
        }
        return nil
    }
}

/// Pick the user-visible string for the current OS language.
@inline(__always)
func L(_ english: String, _ korean: String) -> String {
    if L10n.isKorean { return korean }
    if let table = L10n.table, let hit = table[english] { return hit }
    return english
}
