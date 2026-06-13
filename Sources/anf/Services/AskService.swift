import Foundation

/// On-device Q&A — "ask this document / folder". Builds a context from a file's
/// body (or a folder's document excerpts) and answers questions against it with
/// the local LLM. Fully on-device. Grounded: the model is told to say it doesn't
/// know rather than invent answers not in the text.
enum AskService {

    /// Context text + an optional reason it's empty (so the panel can explain).
    /// Call off the main thread — extraction can be heavy.
    static func context(for url: URL, isFolder: Bool) -> (text: String, reason: String?) {
        if isFolder {
            guard let entries = FastDirRead.list(path: url.path) else {
                return ("", L("This folder can't be read.", "이 폴더를 읽을 수 없어요."))
            }
            let docs = entries.filter {
                !$0.isDir && !$0.isHidden
                && SummaryService.textExts.contains(($0.name as NSString).pathExtension.lowercased())
            }
            guard !docs.isEmpty else {
                return ("", L("This folder has no documents to ask about.",
                              "이 폴더에는 질문할 문서가 없어요."))
            }
            let perDoc = max(400, LocalLLM.inputCharBudget / max(min(docs.count, 12), 1))
            var parts: [String] = []
            var total = 0
            for e in docs.prefix(20) {
                if e.size > SummaryService.folderDocSizeCap { continue }
                guard let body = SummaryService.bodyText(for: url.appendingPathComponent(e.name)) else { continue }
                parts.append("## \(e.name)\n\(String(body.prefix(perDoc)))")
                total += min(body.count, perDoc)
                if total >= LocalLLM.inputCharBudget || parts.count >= 12 { break }
            }
            if parts.isEmpty {
                return ("", L("Couldn’t extract text from this folder’s documents (they look like image-only PDFs).",
                              "이 폴더 문서들에서 텍스트를 추출하지 못했어요 (이미지로 된 PDF로 보입니다)."))
            }
            return (parts.joined(separator: "\n\n"), nil)
        }
        guard let body = SummaryService.bodyText(for: url) else {
            return ("", SummaryService.emptyReason(for: url))
        }
        return (body, nil)
    }

    /// Answer one question against the context, fully on-device. Answers in the
    /// question's language.
    static func answer(question: String, context: String) async -> String {
        guard LocalLLM.isAvailable else { return LocalLLM.unavailableHint(LocalLLM.status) }
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return "" }

        // Answer in the question's language: Korean if the question is Korean,
        // or the OS is Korean and the question isn't clearly English.
        let answerInKorean = LocalLLM.isKorean(q) || (L10n.isKorean && !looksEnglish(q))
        let cjk = LocalLLM.hasCJK(context) || LocalLLM.hasCJK(q)
        let budget = LocalLLM.inputBudget(forCJK: cjk)
        let clipped = context.count > budget ? String(context.prefix(budget)) : context

        let instructions = answerInKorean
            ? "주어진 문서 내용만을 근거로 질문에 한국어로 정확하고 간결하게 답하세요. 문서에 없는 내용이면 '문서에 없습니다'라고 답하세요. 반드시 한국어로만 답하세요."
            : "Answer the question using ONLY the document content below. Be accurate and concise. If the answer isn't in the document, say it isn't there."
        let prompt = "문서:\n\(clipped)\n\n질문: \(q)"
        return await LocalLLM.generate(instructions: instructions, prompt: prompt, maxTokens: 500)
            ?? L("The on-device model couldn’t answer that — try rephrasing.",
                 "온디바이스 모델이 답하지 못했어요 — 질문을 바꿔보세요.")
    }

    /// Rough "is this English?" check to keep an English question in English even
    /// on a Korean OS.
    private static func looksEnglish(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let latin = letters.filter { (0x41...0x5A).contains($0.value) || (0x61...0x7A).contains($0.value) }
        return Double(latin.count) / Double(letters.count) >= 0.7
    }
}
