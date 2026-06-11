import Foundation

/// Lightweight fuzzy matcher in the spirit of fzf: the pattern must appear as a
/// (case-insensitive) subsequence of the text. Score rewards consecutive matches,
/// matches at word boundaries (`/ _ - . space`) and the start of the string, and
/// lightly penalizes long noisy paths. Returns nil when the pattern doesn't match.
enum FuzzyMatch {
    static func score(pattern: String, text: String) -> Int? {
        score(patternChars: Array(pattern.lowercased()), text: text)
    }

    /// Core scorer against a pre-lowercased pattern. Iterates the text's
    /// characters directly (no `Array(text)` allocation — this runs once per URL
    /// for pools of up to 300k entries per keystroke) and exits as soon as the
    /// pattern is fully consumed.
    static func score(patternChars p: [Character], text: String) -> Int? {
        if p.isEmpty { return 0 }

        var pi = 0
        var total = 0
        var prevMatch = -2
        var run = 0
        var ti = 0
        var prevChar: Character = "\0"
        var textCount = 0
        var done = false

        for ch in text.lowercased() {
            textCount += 1
            if done { continue }   // keep counting for the length penalty
            if ch == p[pi] {
                var bonus = 1
                if ti == prevMatch + 1 {
                    run += 1
                    bonus += 5 + run * 2          // consecutive streak
                } else {
                    run = 0
                }
                if ti == 0 {
                    bonus += 10                    // very start
                } else {
                    switch prevChar {
                    case "/", "_", "-", " ", ".": bonus += 8   // word boundary
                    default: break
                    }
                }
                total += bonus
                prevMatch = ti
                pi += 1
                if pi == p.count { done = true }
            }
            prevChar = ch
            ti += 1
        }
        guard done else { return nil }
        total -= textCount / 24                  // prefer shorter / less noisy
        return total
    }

    /// Rank URLs by fuzzy score of the query against the filename (falling back to
    /// the full path), best first, capped at `limit`. The pattern is lowercased
    /// once here, not once per URL.
    static func rank(_ urls: [URL], query: String, limit: Int) -> [URL] {
        let p = Array(query.lowercased())
        var scored: [(url: URL, score: Int)] = []
        scored.reserveCapacity(min(urls.count, 4_096))
        for url in urls {
            if let s = score(patternChars: p, text: url.lastPathComponent) {
                scored.append((url, s))
            } else if let s = score(patternChars: p, text: url.path) {
                scored.append((url, s - 60))
            }
        }
        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map(\.url)
    }

    /// Normalize a string for the pre-lowered index / queries against it: NFC so
    /// scalar-wise comparison is canonical-safe (filesystem paths are often NFD),
    /// then lowercased.
    static func normalizeForIndex(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// Scorer for text that is ALREADY normalized via `normalizeForIndex`.
    /// Compares Unicode scalars, not Characters — grapheme clustering made the
    /// Character version ~6× slower, and scalar equality is correct because both
    /// sides are NFC. Skipping per-call lowercasing + grapheme decoding is what
    /// makes ranking a 300k pool per keystroke cheap (~40ms vs ~500ms).
    static func scoreNormalized(pattern p: [Unicode.Scalar],
                                text: Substring.UnicodeScalarView) -> Int? {
        if p.isEmpty { return 0 }
        var pi = 0
        var total = 0
        var prevMatch = -2
        var run = 0
        var ti = 0
        var prev: Unicode.Scalar = "\0"
        for ch in text {
            if ch == p[pi] {
                var bonus = 1
                if ti == prevMatch + 1 { run += 1; bonus += 5 + run * 2 }
                else { run = 0 }
                if ti == 0 { bonus += 10 }
                else {
                    switch prev {
                    case "/", "_", "-", " ", ".": bonus += 8
                    default: break
                    }
                }
                total += bonus
                prevMatch = ti
                pi += 1
                if pi == p.count {
                    // Length penalty: scalars consumed so far approximates text
                    // length well enough for ranking and avoids an O(n) count.
                    return total - ti / 24
                }
            }
            prev = ch
            ti += 1
        }
        return nil
    }

    /// Rank an index pool: `lowerPaths[i]` is the `normalizeForIndex`-ed form of
    /// `paths[i]`. Matches the filename component first, then the full path.
    /// URLs are materialised for the hits only — building one per pool entry cost
    /// ~770ms at 124k.
    static func rankLowered(paths: [String], lowerPaths: [String],
                            query: String, limit: Int) -> [URL] {
        let p = Array(normalizeForIndex(query).unicodeScalars)
        var scored: [(idx: Int, score: Int)] = []
        scored.reserveCapacity(min(paths.count, 4_096))
        for i in paths.indices {
            let lower = lowerPaths[i]
            let nameStart = lower.lastIndex(of: "/").map { lower.index(after: $0) }
                ?? lower.startIndex
            if let s = scoreNormalized(pattern: p, text: lower[nameStart...].unicodeScalars) {
                scored.append((i, s))
            } else if let s = scoreNormalized(pattern: p, text: lower[...].unicodeScalars) {
                scored.append((i, s - 60))
            }
        }
        scored.sort { $0.score > $1.score }
        return scored.prefix(limit).map { URL(fileURLWithPath: paths[$0.idx]) }
    }
}
