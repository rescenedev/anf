import Foundation
@testable import anf

/// `SmartRule.matches` is the predicate behind sidebar Smart Folders — pure, and
/// previously untested.
func runSmartFolderTests() {
    let u = { (n: String) in URL(fileURLWithPath: "/s/\(n)") }

    T.group("empty rule matches anything") {
        let r = SmartRule()
        T.expect(r.isEmpty, "default rule is empty")
        T.expect(r.matches(url: u("anything.xyz"), modified: nil), "empty rule matches all")
    }

    T.group("nameContains is case-insensitive substring") {
        let r = SmartRule(nameContains: "report")
        T.expect(r.matches(url: u("Q3-REPORT.pdf"), modified: nil), "case-insensitive hit")
        T.expect(!r.matches(url: u("photo.jpg"), modified: nil), "non-match excluded")
    }

    T.group("kindExtensions filters by lowercased extension") {
        let r = SmartRule(kindExtensions: ["pdf", "docx"])
        T.expect(r.matches(url: u("a.PDF"), modified: nil), "extension match is case-insensitive")
        T.expect(r.matches(url: u("b.docx"), modified: nil), "second extension matches")
        T.expect(!r.matches(url: u("c.txt"), modified: nil), "other extension excluded")
    }

    T.group("modifiedWithinDays needs a recent date") {
        let r = SmartRule(modifiedWithinDays: 7)
        T.expect(r.matches(url: u("x.txt"), modified: Date()), "now is within 7 days")
        T.expect(!r.matches(url: u("x.txt"), modified: Date().addingTimeInterval(-30 * 86_400)), "30 days ago excluded")
        T.expect(!r.matches(url: u("x.txt"), modified: nil), "nil modified can't satisfy a time window")
    }

    T.group("rules AND together") {
        let r = SmartRule(nameContains: "tax", kindExtensions: ["pdf"], modifiedWithinDays: nil)
        T.expect(r.matches(url: u("tax-2026.pdf"), modified: nil), "all conditions met")
        T.expect(!r.matches(url: u("tax-2026.txt"), modified: nil), "wrong kind fails the AND")
        T.expect(!r.matches(url: u("photo.pdf"), modified: nil), "wrong name fails the AND")
    }
}
