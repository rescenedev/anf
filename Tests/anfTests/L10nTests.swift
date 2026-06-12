import Foundation
@testable import anf

/// The translation template must stay a valid .strings file covering the
/// static UI strings — a third language is "copy, translate, rebuild".
func runL10nTests() {
    T.group("L10n translation template") {
        let path = "Sources/anf/Resources/l10n/template.strings"
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: String] else {
            T.expect(false, "template parses as a .strings table"); return
        }
        T.expect(dict.count >= 150, "covers the static UI strings (\(dict.count))")
        T.equal(dict["Open"], "열기", "keys are English, values the Korean reference")
        T.expect(!dict.keys.contains { $0.contains("\\(") },
                 "no interpolated keys leak into the table")
    }
}
