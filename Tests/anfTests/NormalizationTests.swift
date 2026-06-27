import Foundation
@testable import anf

func runNormalizationTests() {
    T.group("normalizationVariants") {
        let v = PaletteSearch.normalizationVariants("금융위")
        T.equal(v.count, 2, "korean has NFC + NFD")
        if v.count == 2 {
            T.expect(Array(v[0].utf8) != Array(v[1].utf8), "forms differ in raw bytes")
        }
        T.equal(PaletteSearch.normalizationVariants("hello").count, 1, "ascii single form")
        T.equal(PaletteSearch.normalizationVariants("report.md").count, 1, "ascii single form 2")
    }

    T.group("fdMatcherArgs: NFC/NFD-safe fd pattern") {
        // ASCII → fast literal match.
        T.equal(PaletteSearch.fdMatcherArgs("report"), ["--fixed-strings", "report"],
                "ascii needle uses --fixed-strings")
        // Korean → a single regex pattern OR-ing both normalizations, so an NFC
        // query from the IME also matches NFD on-disk names (the bug: fd byte-
        // matched NFC only and missed NFD Korean filenames).
        let nfc = "한글".precomposedStringWithCanonicalMapping
        let nfd = "한글".decomposedStringWithCanonicalMapping
        T.expect(Array(nfc.utf8) != Array(nfd.utf8), "precondition: NFC and NFD bytes differ")
        let m = PaletteSearch.fdMatcherArgs("한글")
        T.equal(m.count, 1, "korean needle becomes one regex alternation (no --fixed-strings)")
        T.equal(m.first, "\(nfc)|\(nfd)", "alternation contains both NFC and NFD forms")
        // Regex metacharacters in the needle are escaped.
        T.expect(PaletteSearch.regexEscapeLiteral("a.b(c)+").contains("\\.")
                 && PaletteSearch.regexEscapeLiteral("a.b(c)+").contains("\\+"),
                 "regex metacharacters are escaped")
    }
}
