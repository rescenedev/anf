import Foundation

/// On-device "suggest a better name" — reads what a file actually contains
/// (document body, or an image's classifier labels + OCR text) and asks the
/// local LLM for a concise, descriptive filename. Keeps the original extension,
/// answers in the content's language. Fully on-device (telemetry 0).
enum SmartRename {

    /// Longest signal we feed the model — the head carries the gist, and the
    /// name only needs a sentence or two of context.
    static let signalBudget = 2_000

    /// Propose a filename (WITH the original extension). nil when the LLM is
    /// unavailable, no signal could be gathered, or the model returned junk.
    static func suggest(for url: URL) async -> String? {
        guard LocalLLM.isAvailable else { return nil }
        let ext = url.pathExtension
        let signal = await Task.detached(priority: .userInitiated) { signalText(for: url) }.value
        guard let signal, !signal.isEmpty else { return nil }

        let korean = LocalLLM.isKorean(signal)
        let instructions = korean
            ? "파일 내용 설명을 보고 그 파일에 가장 어울리는 간결하고 구체적인 파일명을 한 줄로 제안하세요. 확장자·따옴표·설명 없이 이름만. 공백은 써도 되지만 30자 이내. 반드시 한국어로만 답하세요."
            : "Given a description of a file's contents, propose one concise, specific filename. Reply with the name only — no extension, no quotes, no explanation, one line, under 40 characters."
        guard let raw = await LocalLLM.generate(instructions: instructions, prompt: signal, maxTokens: 40) else {
            return nil
        }
        return sanitize(raw, ext: ext)
    }

    /// What the file is "about", as plain text for the model.
    private static func signalText(for url: URL) -> String? {
        if OCRService.isImage(url) {
            var parts: [String] = []
            let labels = ImageClassifier.labels(for: url)
            if !labels.isEmpty {
                parts.append("Image contents: " + labels.prefix(10).joined(separator: ", "))
            }
            if let ocr = OCRService.recognizeText(in: url, fast: true)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                parts.append("Text in image: " + String(ocr.prefix(400)))
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if let body = SummaryService.bodyText(for: url) {
            return String(body.prefix(signalBudget))
        }
        return nil
    }

    /// Turn the model's reply into a safe filename: strip quotes/extra lines, a
    /// duplicated extension, and HFS-illegal characters; cap the length; then
    /// re-attach the original extension. nil if nothing usable remains.
    static func sanitize(_ raw: String, ext: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.components(separatedBy: .newlines).first ?? name      // first line only
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        // Drop an extension the model echoed back (e.g. "report.pdf" → "report").
        if !ext.isEmpty, name.lowercased().hasSuffix("." + ext.lowercased()) {
            name = String(name.dropLast(ext.count + 1))
        }
        // "/" and ":" are illegal in macOS file names; leading dots hide files.
        name = name.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
        guard !name.isEmpty else { return nil }
        if name.count > 60 {
            name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return ext.isEmpty ? name : name + "." + ext
    }
}
