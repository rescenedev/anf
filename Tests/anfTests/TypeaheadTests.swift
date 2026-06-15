import Foundation
@testable import anf

/// Type-to-select: jamo search keys plus the BrowserModel jump behavior
/// (prefix match, buffer accumulation, pause reset, nearest-follower fallback).
func runTypeaheadTests() {
    T.group("HangulJamo.searchKey") {
        T.equal(HangulJamo.searchKey("플레이"), "ㅍㅡㄹㄹㅔㅇㅣ", "syllables expand to jamo")
        T.equal(HangulJamo.searchKey("Backup"), "backup", "latin just lowercases")
        T.equal(HangulJamo.searchKey("값"), "ㄱㅏㅂㅅ", "tail clusters expand too")
    }

    T.group("HangulJamo: 초성") {
        T.equal(HangulJamo.choseongKey("금융위원회"), "ㄱㅇㅇㅇㅎ", "one lead per syllable")
        T.equal(HangulJamo.choseongKey("(경찰청)규칙A"), "(ㄱㅊㅊ)ㄱㅊa", "non-Hangul passes through lowercased")
        T.expect(HangulJamo.isChoseongQuery("ㄱㅇㅇ"), "consonant run is a 초성 query")
        T.expect(!HangulJamo.isChoseongQuery("ㄱㅏ"), "vowel disqualifies")
        T.expect(!HangulJamo.isChoseongQuery("gy"), "latin disqualifies")
        T.expect(HangulJamo.choseongMatches(pattern: "ㄱ", text: "금"), "ㄱ matches 금")
        T.expect(!HangulJamo.choseongMatches(pattern: "ㄴ", text: "금"), "ㄴ doesn't match 금")
    }

    T.group("FuzzyMatch: 초성 subsequence") {
        T.expect(FuzzyMatch.score(pattern: "ㄱㅇㅇㅇㅎ", text: "금융위원회") != nil,
                 "full 초성 run matches in the fuzzy scorer")
        T.expect(FuzzyMatch.score(pattern: "ㄱㅇㅇ", text: "(금융위원회)감독규정") != nil,
                 "partial 초성 matches inside decorated names")
        let p = Array(FuzzyMatch.normalizeForIndex("ㄱㅇㅇ").unicodeScalars)
        let t = FuzzyMatch.normalizeForIndex("(금융위원회)감독규정")
        T.expect(FuzzyMatch.scoreNormalized(pattern: p, text: t[...].unicodeScalars) != nil,
                 "scalar scorer (index path) matches 초성 too")
    }

    MainActor.assumeIsolated {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("anftype-\(UUID().uuidString)")
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            for name in ["archives", "backup", "blog", "playground", "presentation",
                         "플레이그라운드", "(금융위원회)감독규정"] {
                try fm.createDirectory(at: dir.appendingPathComponent(name),
                                       withIntermediateDirectories: true)
            }
        } catch { T.expect(false, "fixture setup threw: \(error)"); return }
        defer { try? fm.removeItem(at: dir) }

        let model = BrowserModel(start: dir)
        let deadline = Date().addingTimeInterval(5)
        while model.items.count != 7 && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        T.equal(model.fileItems.count, 7, "fixture listing loaded")
        guard model.fileItems.count == 7 else { return }

        @MainActor func selectedName() -> String {
            model.items.first { model.selection.contains($0.id) }?.name ?? "(none)"
        }
        let t0 = Date()

        T.group("typeSelect: prefix jump and accumulation") {
            model.typeSelect("p", now: t0)
            T.equal(selectedName(), "playground", "'p' jumps to the first p-item")
            model.typeSelect("r", now: t0.addingTimeInterval(0.3))
            T.equal(selectedName(), "presentation", "quick 'r' accumulates to 'pr'")
        }

        T.group("typeSelect: pause resets the buffer") {
            model.typeSelect("b", now: t0.addingTimeInterval(3))
            T.equal(selectedName(), "backup", "after a pause 'b' starts fresh")
            model.typeSelect("l", now: t0.addingTimeInterval(3.2))
            T.equal(selectedName(), "blog", "'bl' refines within the window")
        }

        T.group("typeSelect: Korean jamo matching") {
            model.typeSelect("ㅍ", now: t0.addingTimeInterval(6))
            T.equal(selectedName(), "플레이그라운드", "initial consonant finds the Korean name")
            model.typeSelect("ㅡ", now: t0.addingTimeInterval(6.2))
            T.equal(selectedName(), "플레이그라운드", "IME jamo stream keeps matching")
        }

        T.group("typeSelect: no-match falls to the nearest follower") {
            model.typeSelect("c", now: t0.addingTimeInterval(9))
            T.equal(selectedName(), "playground",
                    "no c-item → alphabetically nearest following name")
        }

        T.group("typeSelect: Korean IME falls back to the physical key") {
            model.typeSelect("ㅂ", fallback: "b", now: t0.addingTimeInterval(12))
            T.equal(selectedName(), "backup",
                    "ㅂ has no Korean match → physical 'b' finds backup")
            model.typeSelect("ㅣ", fallback: "l", now: t0.addingTimeInterval(12.2))
            T.equal(selectedName(), "blog", "mixed buffer keeps using the latin stream")
            model.typeSelect("ㅍ", fallback: "v", now: t0.addingTimeInterval(15))
            T.equal(selectedName(), "플레이그라운드",
                    "Korean prefix still wins over the fallback letter")
        }

        T.group("typeSelect: 초성 run jumps by syllable leads") {
            model.typeSelect("ㄱ", now: t0.addingTimeInterval(18))
            model.typeSelect("ㅇ", now: t0.addingTimeInterval(18.2))
            model.typeSelect("ㅇ", now: t0.addingTimeInterval(18.4))
            T.equal(selectedName(), "(금융위원회)감독규정",
                    "ㄱㅇㅇ reaches 금융위원회 (the regression: vowels interleaved in the full key)")
        }
    }
}
