import Foundation

/// Bridges anf's text extraction to the on-device LLM for summarization
/// (inspector button, right-click menu, folder overview).
enum SummaryService {

    /// Extensions worth summarizing when sweeping a folder.
    static let textExts: Set<String> = [
        "hwpx", "docx", "pptx", "xlsx", "pdf", "md", "markdown", "txt", "rtf",
        "json", "csv", "log", "swift", "js", "ts", "py", "rb", "go", "rs",
        "c", "h", "cpp", "sh", "yaml", "yml", "html", "xml", "css",
    ]

    /// Body text for a single file, or nil. hwpx/docx go through the STRUCTURED
    /// parsers (not the tag-strip extractor) so form-field junk like
    /// "Clickhere:set:45:Direction…" never pollutes the summary; pptx/xlsx/pdf
    /// use DocumentText; everything else is read directly.
    static func bodyText(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "hwpx": return clean(blocksToText(HwpxStructure.parse(hwpxAt: url)))
        case "docx": return clean(blocksToText(DocxStructure.parse(docxAt: url)))
        default: break
        }
        if DocumentText.canExtract(ext) {            // pptx/xlsx/pdf
            return clean(DocumentTextCache.shared.text(for: url))
        }
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return clean(String(decoding: data.prefix(LocalLLM.inputCharBudget * 2), as: UTF8.self))
    }

    private static func clean(_ s: String?) -> String? {
        let t = (s ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private static func blocksToText(_ blocks: [DocxBlock]) -> String {
        blocks.map { block in
            switch block {
            case .header(_, let t): return t
            case .paragraph(let runs): return runs.map(\.text).joined()
            case .listItem(let t, _): return "• " + t
            case .table(let rows): return rows.map { $0.joined(separator: "  ") }.joined(separator: "\n")
            }
        }.joined(separator: "\n")
    }

    /// Extract (off the caller's actor) then summarize one file.
    static func summarize(url: URL) async -> String? {
        let text = await Task.detached(priority: .userInitiated) { bodyText(for: url) }.value
        guard let text else { return nil }
        return await LocalLLM.summarize(text)
    }

    /// Summarize a FOLDER: gather its summarizable documents, take an excerpt of
    /// each, and ask the model for an overview of what the folder contains.
    static func summarizeFolder(url: URL) async -> String? {
        let combined = await Task.detached(priority: .userInitiated) { () -> (text: String, count: Int)? in
            guard let entries = FastDirRead.list(path: url.path) else { return nil }
            let docs = entries
                .filter { !$0.isDir && !$0.isHidden && textExts.contains(($0.name as NSString).pathExtension.lowercased()) }
                .prefix(20)
            guard !docs.isEmpty else { return nil }

            let perDoc = max(400, LocalLLM.inputCharBudget / max(docs.count, 1))
            var parts: [String] = []
            var total = 0
            for e in docs {
                let fileURL = url.appendingPathComponent(e.name)
                guard let body = bodyText(for: fileURL) else { continue }
                let excerpt = String(body.prefix(perDoc))
                parts.append("## \(e.name)\n\(excerpt)")
                total += excerpt.count
                if total >= LocalLLM.inputCharBudget { break }
            }
            return parts.isEmpty ? nil : (parts.joined(separator: "\n\n"), parts.count)
        }.value

        guard let combined else { return nil }
        let korean = LocalLLM.isKorean(combined.text)
        let instructions = korean
            ? "여러 문서의 발췌를 읽고, 이 폴더가 전반적으로 어떤 내용인지 한국어로 3~5문장 개요로 정리하세요. 주요 주제와 문서 종류를 묶어서. 반드시 한국어로만 답하세요."
            : "Given excerpts from several documents, write a 3–5 sentence overview of what this folder contains — group the main themes and document types."
        let prompt = "폴더: \(url.lastPathComponent)\n\n\(combined.text)"
        return await LocalLLM.generate(instructions: instructions, prompt: prompt, maxTokens: 500)
    }
}
