import Foundation
import PDFKit

/// Bridges anf's text extraction to the on-device LLM for summarization
/// (inspector button, right-click menu, folder overview). Returns a USER-FACING
/// string in every case — a summary, or a precise reason it couldn't (so the
/// UI never has to show a useless "Couldn't summarize this").
enum SummaryService {

    /// Extensions worth summarizing when sweeping a folder.
    static let textExts: Set<String> = [
        "hwpx", "docx", "pptx", "xlsx", "pdf", "md", "markdown", "txt", "rtf",
        "json", "csv", "log", "swift", "js", "ts", "py", "rb", "go", "rs",
        "c", "h", "cpp", "sh", "yaml", "yml", "html", "xml", "css",
    ]

    /// Don't try to extract text from a document bigger than this during a folder
    /// sweep — a 600MB image-only slide PDF has no text anyway and just burns
    /// memory. Single-file summarize still tries (the user picked that file).
    static let folderDocSizeCap: Int64 = 60 * 1024 * 1024

    /// Body text for a single file, or nil. hwpx/docx go through the STRUCTURED
    /// parsers; pptx/xlsx/pdf use DocumentText; everything else is read directly.
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

    /// Precise reason a file yielded no text — so we can tell the user exactly
    /// what's wrong instead of a generic failure.
    static func emptyReason(for url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" {
            if let doc = PDFDocument(url: url) {
                if doc.isLocked {
                    return L("This PDF is password-protected, so its text can't be read.",
                             "이 PDF는 암호로 보호되어 있어 텍스트를 읽을 수 없어요.")
                }
                return L("This PDF has no text layer — it's image-only (scanned pages or slide images), so there's nothing to extract. It would need OCR.",
                         "이 PDF에는 텍스트 레이어가 없어요 — 이미지로만 된 PDF(스캔본·슬라이드 이미지)라 추출할 텍스트가 없습니다. OCR이 필요해요.")
            }
            return L("This PDF couldn't be opened.", "이 PDF를 열 수 없어요.")
        }
        if OCRService.isImage(url) {
            return L("This is an image. Use ‘Suggest Name’, which reads it with OCR.",
                     "이미지 파일이에요. OCR로 읽는 ‘AI 이름 제안’을 사용해 보세요.")
        }
        return L("Couldn’t read any text from this file.",
                 "이 파일에서 읽을 수 있는 텍스트를 찾지 못했어요.")
    }

    /// Summarize one file. Always returns a user-facing string (summary or why
    /// not).
    static func summarize(url: URL) async -> String {
        guard LocalLLM.isAvailable else { return LocalLLM.unavailableHint(LocalLLM.status) }
        let text = await Task.detached(priority: .userInitiated) { bodyText(for: url) }.value
        guard let text else {
            return await Task.detached(priority: .userInitiated) { emptyReason(for: url) }.value
        }
        guard let summary = await LocalLLM.summarize(text) else {
            return L("The on-device model didn’t respond — try again shortly.",
                     "온디바이스 모델이 응답하지 않았어요 — 잠시 후 다시 시도하세요.")
        }
        return summary
    }

    /// Images to actually open (OCR + classify) when describing an image folder.
    static let imageSampleCap = 15

    /// What a folder sweep collected, off the main thread.
    private struct FolderScan {
        var bodies = ""        // extracted document text
        var imageDigest = ""   // labels + OCR from sampled images
        var names: [String] = []
        var imageCount = 0
    }

    /// Summarize a FOLDER. Reads its documents; if there's no document text,
    /// analyzes its IMAGES (classifier labels + OCR); if neither, infers from the
    /// FILE NAMES — always returning something useful and saying which it used.
    static func summarizeFolder(url: URL) async -> String {
        guard LocalLLM.isAvailable else { return LocalLLM.unavailableHint(LocalLLM.status) }

        let scan = await Task.detached(priority: .userInitiated) { () -> FolderScan? in
            guard let entries = FastDirRead.list(path: url.path) else { return nil }
            let files = entries.filter { !$0.isDir && !$0.isHidden }
            guard !files.isEmpty else { return nil }
            var s = FolderScan()
            s.names = files.map(\.name)

            // 1) Documents.
            let docs = files.filter { textExts.contains(($0.name as NSString).pathExtension.lowercased()) }
            let perDoc = max(400, LocalLLM.inputCharBudget / max(min(docs.count, 20), 1))
            var parts: [String] = []
            var total = 0
            for e in docs.prefix(40) {
                if e.size > folderDocSizeCap { continue }
                guard let body = bodyText(for: url.appendingPathComponent(e.name)) else { continue }
                parts.append("## \(e.name)\n\(String(body.prefix(perDoc)))")
                total += min(body.count, perDoc)
                if total >= LocalLLM.inputCharBudget || parts.count >= 20 { break }
            }
            s.bodies = parts.joined(separator: "\n\n")

            // 2) Images — only worth the OCR/classify cost if there's no doc text.
            let images = files.filter { OCRService.isImage(url.appendingPathComponent($0.name)) }
            s.imageCount = images.count
            if s.bodies.isEmpty && !images.isEmpty {
                var lines: [String] = []
                for e in images.prefix(imageSampleCap) {
                    let img = url.appendingPathComponent(e.name)
                    var bits: [String] = []
                    let labels = ImageClassifier.labels(for: img)
                    if !labels.isEmpty { bits.append(labels.prefix(5).joined(separator: ", ")) }
                    if let ocr = OCRService.recognizeText(in: img, fast: true)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                        bits.append("“\(String(ocr.prefix(150)))”")
                    }
                    if !bits.isEmpty { lines.append("- \(e.name): " + bits.joined(separator: " / ")) }
                }
                s.imageDigest = lines.joined(separator: "\n")
            }
            return s
        }.value

        guard let scan else {
            return L("This folder is empty.", "이 폴더는 비어 있어요.")
        }

        // 1) Document text.
        if !scan.bodies.isEmpty {
            let korean = LocalLLM.isKorean(scan.bodies)
            let instructions = korean
                ? "여러 문서의 발췌를 읽고, 이 폴더가 전반적으로 어떤 내용인지 한국어로 3~5문장 개요로 정리하세요. 주요 주제와 문서 종류를 묶어서. 반드시 한국어로만 답하세요."
                : "Given excerpts from several documents, write a 3–5 sentence overview of what this folder contains — group the main themes and document types."
            return await generateOrRetryHint(instructions, "폴더: \(url.lastPathComponent)\n\n\(scan.bodies)", 500)
        }

        // 2) Image analysis.
        if !scan.imageDigest.isEmpty {
            let korean = LocalLLM.isKorean(scan.imageDigest) || L10n.isKorean
            let instructions = korean
                ? "다음은 폴더 속 이미지들의 분류 라벨과 인식된 텍스트입니다. 이 이미지들이 전반적으로 무엇에 관한 것인지 한국어 3~5문장으로 정리하세요. 반드시 한국어로만 답하세요."
                : "Below are classifier labels and OCR text from images in a folder. Summarize in 3–5 sentences what these images are about."
            let result = await generateOrRetryHint(instructions, "폴더: \(url.lastPathComponent)\n\(scan.imageDigest)", 400)
            let note = korean
                ? "\n\n(이미지 \(min(scan.imageCount, imageSampleCap))/\(scan.imageCount)개를 OCR·분류로 분석한 결과예요.)"
                : "\n\n(Analyzed \(min(scan.imageCount, imageSampleCap)) of \(scan.imageCount) images via OCR + classification.)"
            return result + note
        }

        // 3) File names only.
        let nameList = scan.names.prefix(60).joined(separator: "\n")
        let korean = LocalLLM.isKorean(nameList) || L10n.isKorean
        let instructions = korean
            ? "다음은 한 폴더 안의 파일 이름 목록입니다. 이 폴더가 무엇에 관한 것인지 이름만으로 한국어 2~3문장으로 추정해 설명하세요. 반드시 한국어로만 답하세요."
            : "Below are the file names in one folder. From the names alone, infer in 2–3 sentences what this folder is about."
        let note = korean
            ? "\n\n(참고: 본문을 추출하지 못해 파일 이름만으로 추정한 결과예요.)"
            : "\n\n(Note: inferred from file names only — contents couldn't be extracted.)"
        return await generateOrRetryHint(instructions, "폴더: \(url.lastPathComponent)\n\(nameList)", 300) + note
    }

    /// generate(), or a "try again" hint when the model returns nothing.
    private static func generateOrRetryHint(_ instructions: String, _ prompt: String, _ maxTokens: Int) async -> String {
        await LocalLLM.generate(instructions: instructions, prompt: prompt, maxTokens: maxTokens)
            ?? L("The on-device model didn’t respond — try again shortly.",
                 "온디바이스 모델이 응답하지 않았어요 — 잠시 후 다시 시도하세요.")
    }
}
