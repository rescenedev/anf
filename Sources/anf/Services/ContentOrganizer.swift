import Foundation

/// Sort a folder's files into topic folders by what they're ABOUT, using the
/// on-device LLM — "내용별 분류". Each file gets one category from a fixed
/// taxonomy (a constrained choice is far more reliable than free-form from a
/// small on-device model), then files move into the matching folder. Fully
/// on-device. Bounded so a giant Downloads folder can't run away.
enum ContentOrganizer {

    struct Cat: Sendable { let ko: String; let en: String }

    /// Fixed taxonomy. "Other" is the catch-all when nothing fits.
    static let taxonomy: [Cat] = [
        Cat(ko: "영수증·청구서", en: "Receipts & Invoices"),
        Cat(ko: "보고서", en: "Reports"),
        Cat(ko: "프레젠테이션", en: "Presentations"),
        Cat(ko: "계약·법무", en: "Contracts & Legal"),
        Cat(ko: "이력서", en: "Resumes"),
        Cat(ko: "매뉴얼·가이드", en: "Manuals & Guides"),
        Cat(ko: "학습·강의", en: "Learning"),
        Cat(ko: "금융·투자", en: "Finance"),
        Cat(ko: "개발·기술", en: "Development"),
        Cat(ko: "기타", en: "Other"),
    ]

    static var otherName: String { L10n.isKorean ? "기타" : "Other" }
    static func names() -> [String] { taxonomy.map { L10n.isKorean ? $0.ko : $0.en } }

    /// Max files to classify in one run (each is an LLM call). Above this we
    /// classify the first N and report the rest as skipped.
    static let maxFiles = 200

    /// Files worth classifying: those whose contents we can actually read
    /// (documents, PDFs, text/code, images via OCR). Non-recursive; folders and
    /// our own category folders are skipped.
    static func candidates(in folder: URL) -> [URL] {
        let buckets = Set(taxonomy.flatMap { [$0.ko, $0.en] })
        guard let entries = FastDirRead.list(path: folder.path) else { return [] }
        var out: [URL] = []
        for e in entries where !e.isDir && !e.isHidden {
            if buckets.contains(e.name) { continue }
            let url = folder.appendingPathComponent(e.name)
            guard let item = FileItem(url: url) else { continue }
            if item.hasSummarizableText || OCRService.isImage(url) { out.append(url) }
        }
        return out
    }

    /// Classify one file into a localized category name (off the main thread for
    /// the read; the LLM call is async). Returns `otherName` on a weak/no match.
    static func categorize(_ url: URL) async -> String {
        let signal = await Task.detached(priority: .userInitiated) { signalText(for: url) }.value
        guard let signal, signal.count >= 8 else { return otherName }

        let opts = names()
        let list = opts.joined(separator: ", ")
        let instructions = L10n.isKorean
            ? "파일 내용을 보고 아래 분류 중 정확히 하나를 고르세요. 분류 이름만 그대로 출력하고 다른 말은 하지 마세요. 명확히 맞는 분류가 없을 때만 '기타'를 고르세요.\n분류: \(list)"
            : "Pick exactly ONE category for this file from the list. Output only the category name, nothing else. Use 'Other' only when nothing else clearly fits.\nCategories: \(list)"
        let reply = await LocalLLM.generate(instructions: instructions, prompt: signal, maxTokens: 16)
        return match(reply, in: opts) ?? otherName
    }

    /// Map a fuzzy model reply onto one of the allowed names.
    static func match(_ reply: String?, in options: [String]) -> String? {
        guard let r = reply?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !r.isEmpty else {
            return nil
        }
        // Exact/substring either direction (the model may add or drop words).
        if let exact = options.first(where: { $0.lowercased() == r }) { return exact }
        return options.first { r.contains($0.lowercased()) || $0.lowercased().contains(r) }
    }

    /// Build a signal string for classification (short — a category needs less
    /// than a summary). Always includes the file name so even an unreadable file
    /// can be placed by its name; content (OCR-leading for images) via the shared
    /// extractor.
    private static func signalText(for url: URL) -> String? {
        let name = "File name: \(url.lastPathComponent)"
        if let content = ContentSignal.text(for: url, maxChars: 1_500) {
            return name + "\n" + content
        }
        return name
    }

    /// Move classified files into their category folders (off the main thread).
    static func move(groups: [String: [URL]], into folder: URL) -> (moved: Int, failed: Int) {
        let fm = FileManager.default
        var moved = 0, failed = 0
        for (category, urls) in groups {
            let dir = folder.appendingPathComponent(category)
            do { try fm.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch { failed += urls.count; continue }
            for src in urls {
                let name = ScreenshotOrganizer.uniqueName(in: dir, fileName: src.lastPathComponent)
                do { try fm.moveItem(at: src, to: dir.appendingPathComponent(name)); moved += 1 }
                catch { failed += 1 }
            }
        }
        return (moved, failed)
    }
}
