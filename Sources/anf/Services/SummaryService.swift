import Foundation

/// Bridges anf's text extraction to the on-device LLM for the inspector's
/// summarize button. Pulls a file's body text (office/pdf via DocumentText,
/// plain/markdown/json/code by reading the file) and hands it to LocalLLM.
enum SummaryService {

    /// Body text for any summarizable file, or nil.
    static func bodyText(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if DocumentText.canExtract(ext) {            // hwpx/docx/pptx/xlsx/pdf
            return DocumentTextCache.shared.text(for: url)
        }
        // plain text / markdown / json / source — read directly (bounded).
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        let s = String(decoding: data.prefix(LocalLLM.inputCharBudget * 2), as: UTF8.self)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Extract (off the caller's actor) then summarize. nil if no text or the
    /// LLM is unavailable.
    static func summarize(url: URL) async -> String? {
        let text = await Task.detached(priority: .userInitiated) { bodyText(for: url) }.value
        guard let text else { return nil }
        return await LocalLLM.summarize(text)
    }
}
