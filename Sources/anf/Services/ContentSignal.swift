import Foundation

/// One place to turn a file into "what it's about" text for the LLM — OCR-leading
/// for images (UI/document text identifies a screenshot; classifier labels are a
/// weak hint), document body otherwise. Shared by auto-tag and folder analysis so
/// they read a file the same way.
enum ContentSignal {
    static func text(for url: URL, maxChars: Int) -> String? {
        if OCRService.isImage(url) {
            var parts: [String] = []
            if let ocr = OCRService.recognizeText(in: url)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                parts.append("Text: " + String(ocr.prefix(maxChars)))
            }
            let labels = ImageClassifier.labels(for: url)
            if !labels.isEmpty { parts.append("Visual: " + labels.prefix(6).joined(separator: ", ")) }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if let body = SummaryService.bodyText(for: url) { return String(body.prefix(maxChars)) }
        return nil
    }
}
