import Foundation
@testable import anf

func runFuzzyMatchTests() {
    T.group("FuzzyMatch") {
        T.notNil(FuzzyMatch.score(pattern: "fin", text: "finder"), "fin matches finder")
        T.notNil(FuzzyMatch.score(pattern: "fdr", text: "finder"), "scattered subsequence")
        T.isNil(FuzzyMatch.score(pattern: "xyz", text: "finder"), "non-subsequence misses")
        T.isNil(FuzzyMatch.score(pattern: "finderr", text: "finder"), "longer than text misses")
        T.equal(FuzzyMatch.score(pattern: "", text: "anything"), 0, "empty pattern scores 0")
        T.notNil(FuzzyMatch.score(pattern: "FIN", text: "finder"), "case-insensitive")
        T.notNil(FuzzyMatch.score(pattern: "금융위", text: "(금융위원회)규정"), "korean subsequence")
        T.isNil(FuzzyMatch.score(pattern: "교육부", text: "(금융위원회)규정"), "korean miss")

        if let a = FuzzyMatch.score(pattern: "abc", text: "abcxyz"),
           let b = FuzzyMatch.score(pattern: "abc", text: "axbxc") {
            T.expect(a > b, "consecutive beats scattered")
        } else { T.expect(false, "scores present") }

        let urls = [URL(fileURLWithPath: "/x/zzz_report_draft.txt"),
                    URL(fileURLWithPath: "/x/report.txt"),
                    URL(fileURLWithPath: "/x/unrelated.md")]
        let ranked = FuzzyMatch.rank(urls, query: "report", limit: 10)
        T.equal(ranked.first?.lastPathComponent, "report.txt", "best match first")
        T.expect(!ranked.contains { $0.lastPathComponent == "unrelated.md" }, "misses excluded")
        T.expect(FuzzyMatch.rank(urls, query: "r", limit: 1).count <= 1, "limit respected")
    }
}
