import Foundation

/// On-device auto-tagging: read what a file is about and suggest a few short
/// topic tags, written as real Finder tags (NSURLTagNamesKey) so they show up in
/// Finder too. Merges with existing tags — never clobbers colour labels. Fully
/// on-device; refuses generic/junk tags.
enum TagService {

    static let maxTags = 3

    /// Tags too generic to be useful.
    private static let banned: Set<String> = [
        "document", "file", "image", "photo", "screenshot", "untitled", "misc",
        "other", "general", "stuff", "data", "문서", "파일", "이미지", "사진",
        "스크린샷", "기타", "일반", "자료",
    ]

    /// Suggest 1–3 topic tags for a file (empty when the LLM is unavailable, the
    /// content is unreadable, or nothing useful came back).
    static func suggest(for url: URL) async -> [String] {
        guard LocalLLM.isAvailable else { return [] }
        let signal = await Task.detached(priority: .userInitiated) {
            ContentSignal.text(for: url, maxChars: 1_500)
        }.value
        guard let signal, signal.count >= 8 else { return [] }

        let korean = LocalLLM.isKorean(signal) || L10n.isKorean
        let instructions = korean
            ? "파일 내용을 보고 핵심 주제를 나타내는 짧은 태그 2~3개를 쉼표로 구분해 출력하세요. 태그만, 설명·해시(#)·확장자 없이. 너무 일반적인 단어(문서/이미지/기타) 금지. 예: 계약서, 법무, 2026"
            : "Read the file and output 2–3 short topic tags, comma-separated. Tags only — no explanation, no #, no extension. Avoid generic words (document, image, misc). Example: invoice, finance, 2026"
        guard let raw = await LocalLLM.generate(instructions: instructions, prompt: signal, maxTokens: 24) else {
            return []
        }
        return parse(raw)
    }

    /// Parse the model's reply into clean, deduped tags.
    static func parse(_ raw: String) -> [String] {
        let pieces = raw
            .replacingOccurrences(of: "\n", with: ",")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'`#.-•")) }
        var out: [String] = []
        var seen = Set<String>()
        for p in pieces {
            guard !p.isEmpty, p.count <= 20 else { continue }
            let key = p.lowercased()
            if banned.contains(key) || seen.contains(key) { continue }
            seen.insert(key)
            out.append(p)
            if out.count >= maxTags { break }
        }
        return out
    }

    /// Add tags to a file, merging with what's there (case-insensitive), so
    /// existing colour labels and tags survive.
    static func apply(_ tags: [String], to url: URL) {
        guard !tags.isEmpty else { return }
        var current = FileTags.tags(of: url)
        let have = Set(current.map { $0.lowercased() })
        for t in tags where !have.contains(t.lowercased()) { current.append(t) }
        FileTags.setTags(current, on: url)
    }
}
