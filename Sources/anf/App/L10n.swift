import Foundation

/// UI language follows the OS: Korean for Korean-locale users, English otherwise.
/// A two-literal helper instead of .strings catalogs — anf has ~80 strings, no
/// Xcode, and grep-ability beats indirection at this size.
enum L10n {
    static let isKorean: Bool =
        Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
}

/// Pick the user-visible string for the current OS language.
@inline(__always)
func L(_ english: String, _ korean: String) -> String {
    L10n.isKorean ? korean : english
}
