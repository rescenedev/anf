import Foundation

/// On-device "suggest a better name" — reads what a file actually contains
/// (image OCR text first, then classifier labels; or a document's body) and
/// asks the local LLM for a concise, content-based filename. Keeps the original
/// extension, answers in the content's language, and refuses lazy/generic
/// guesses (a "no suggestion" beats "Screenshot_2026…"). Fully on-device.
enum SmartRename {

    static let signalBudget = 2_000

    /// Words a good name must never be — if the model falls back to one of these
    /// we treat it as "no idea" rather than show junk.
    private static let bannedWords = [
        "screenshot", "screen shot", "screen capture", "스크린샷", "스크린 샷",
        "untitled", "image", "photo", "picture", "document", "file", "이미지",
        "사진", "그림", "문서", "파일", "제목 없음", "캡처",
    ]

    /// Extensions we strip if the model tacks one on (kills ".jpg.png").
    private static let knownExts: Set<String> = [
        "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff", "bmp", "pdf",
        "doc", "docx", "hwpx", "hwp", "pptx", "ppt", "xlsx", "xls", "txt",
        "md", "rtf", "json", "csv",
    ]

    /// Propose a filename (WITH the original extension), or nil when the LLM is
    /// unavailable, the signal is too thin, or the model returned junk.
    static func suggest(for url: URL) async -> String? {
        guard LocalLLM.isAvailable else { return nil }
        let ext = url.pathExtension
        let signal = await Task.detached(priority: .userInitiated) { signalText(for: url) }.value
        guard let signal, signal.count >= 8 else { return nil }   // too little to name well

        let korean = LocalLLM.isKorean(signal)
        let instructions = korean
            ? """
              파일 내용을 보고 그 파일의 주제를 나타내는 이름을 지으세요.
              규칙:
              - 이름만 한 줄로 출력. 설명·따옴표·확장자 금지.
              - 날짜·시간·일련번호 금지.
              - '스크린샷', '이미지', '사진', '문서', '캡처' 같은 일반 단어 금지.
              - 내용에 보이는 앱 이름·제목·핵심 주제를 2~6단어로.
              예: 결제 대시보드 화면 → 결제 대시보드 현황
              반드시 한국어로만 답하세요.
              """
            : """
              Name this file after its actual subject, based on its contents.
              Rules:
              - Output only the name, one line. No explanation, quotes, or extension.
              - No dates, times, or serial numbers.
              - Never use generic words: screenshot, image, photo, document, file, untitled.
              - Use the app name, title, or main topic visible in the content, 2–6 words.
              Example: a Stripe payments dashboard → Stripe Payments Dashboard
              """
        guard let raw = await LocalLLM.generate(instructions: instructions, prompt: signal, maxTokens: 32) else {
            return nil
        }
        guard let name = sanitize(raw, ext: ext) else { return nil }
        return isLazy(name, ext: ext) ? nil : name
    }

    /// What the file is "about", as plain text for the model. For images the OCR
    /// text leads (UI/document text is what identifies a screenshot); classifier
    /// labels are a weak secondary hint.
    private static func signalText(for url: URL) -> String? {
        if OCRService.isImage(url) {
            var parts: [String] = []
            if let ocr = OCRService.recognizeText(in: url)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !ocr.isEmpty {
                parts.append("Text shown:\n" + String(ocr.prefix(1_000)))
            }
            let labels = ImageClassifier.labels(for: url)
            if !labels.isEmpty {
                parts.append("Visual: " + labels.prefix(6).joined(separator: ", "))
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        if let body = SummaryService.bodyText(for: url) {
            return String(body.prefix(signalBudget))
        }
        return nil
    }

    /// Turn the model's reply into a safe filename: first line only, strip
    /// quotes, drop ANY trailing known extension, replace HFS-illegal chars,
    /// trim leading dots, cap length; then re-attach the original extension.
    static func sanitize(_ raw: String, ext: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        name = name.components(separatedBy: .newlines).first ?? name
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'`“”‘’"))
        // Strip a trailing extension the model added (e.g. "report.pdf",
        // "shot.jpg") — twice, to catch a doubled ".jpg.png".
        for _ in 0..<2 {
            let ns = name as NSString
            let tail = ns.pathExtension.lowercased()
            if !tail.isEmpty, knownExts.contains(tail) || tail == ext.lowercased() {
                name = ns.deletingPathExtension
            }
        }
        name = name.replacingOccurrences(of: "/", with: "-")
                   .replacingOccurrences(of: ":", with: "-")
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". \t"))
        guard !name.isEmpty else { return nil }
        if name.count > 60 {
            name = String(name.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return ext.isEmpty ? name : name + "." + ext
    }

    /// Reject lazy output: a banned generic word, or a name with almost no
    /// letters (i.e. it's basically a date/number) — better to show nothing.
    static func isLazy(_ fileName: String, ext: String) -> Bool {
        let stem = (fileName as NSString).deletingPathExtension.lowercased()
        if bannedWords.contains(where: { stem.contains($0) }) { return true }
        let letters = stem.unicodeScalars.filter {
            CharacterSet.letters.contains($0)
        }.count
        return letters < 3
    }
}
