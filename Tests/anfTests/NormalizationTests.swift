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
}
