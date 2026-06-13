import Foundation
@testable import anf

/// On-device LLM plumbing that's testable WITHOUT Apple Intelligence enabled:
/// availability gating, hints, body-text extraction for the summarizer, and
/// graceful degradation (generate → nil when unavailable).
func runLLMTests() {
    let fm = FileManager.default
    let dir = fm.temporaryDirectory.appendingPathComponent("anfllm-\(UUID().uuidString)")
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: dir) }

    T.group("LocalLLM availability gating") {
        // Whatever the machine reports, status maps to a stable hint and
        // isAvailable agrees with .available.
        let s = LocalLLM.status
        T.equal(LocalLLM.isAvailable, s == .available, "isAvailable tracks status")
        if s != .available {
            T.expect(!LocalLLM.unavailableHint(s).isEmpty, "unavailable states carry a hint")
        }
        T.equal(LocalLLM.unavailableHint(.available), "", "available has no hint")
    }

    T.group("SummaryService.bodyText reads text files") {
        let md = dir.appendingPathComponent("note.md")
        try? "# Title\n\nBody text here.".write(to: md, atomically: true, encoding: .utf8)
        let body = SummaryService.bodyText(for: md)
        T.expect(body?.contains("Body text here") == true, "markdown body read")

        let empty = dir.appendingPathComponent("empty.txt")
        try? "".write(to: empty, atomically: true, encoding: .utf8)
        T.expect(SummaryService.bodyText(for: empty) == nil, "empty file → nil")
    }

    T.group("summarize degrades gracefully when LLM unavailable") {
        if !LocalLLM.isAvailable {
            let md = dir.appendingPathComponent("d.md")
            try? "Some content to summarize.".write(to: md, atomically: true, encoding: .utf8)
            let sem = DispatchSemaphore(value: 0)
            var result = "unset"
            Task { result = await SummaryService.summarize(url: md); sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
            // No model → a clear hint string, not a crash/hang or empty result.
            T.equal(result, LocalLLM.unavailableHint(LocalLLM.status),
                    "no model → summarize returns the availability hint")
        }
    }

    T.group("emptyReason explains why extraction failed") {
        let pdf = dir.appendingPathComponent("scan.pdf")
        try? Data("%PDF-1.4 not really a pdf".utf8).write(to: pdf)
        T.expect(!SummaryService.emptyReason(for: pdf).isEmpty, "pdf gets a specific reason")
        let img = dir.appendingPathComponent("p.png")
        try? Data("x".utf8).write(to: img)
        T.expect(SummaryService.emptyReason(for: img).contains("OCR")
                 || SummaryService.emptyReason(for: img).contains("이름"),
                 "image points the user to OCR/Suggest Name")
    }

    T.group("language detection for summary instruction") {
        T.expect(LocalLLM.isKorean("금융위원회는 규정을 개정한다"), "Hangul → Korean")
        T.expect(LocalLLM.isKorean("외국인 통합계좌에 ETF와 ETN 추가"), "Korean with loanwords stays Korean")
        T.expect(!LocalLLM.isKorean("The quarterly report shows revenue growth"), "English → not Korean")
        T.expect(!LocalLLM.isKorean("{\"key\": 123, \"name\": \"value\"}"), "json/ascii → not Korean")
    }

    T.group("CJK detection drives the tighter token budget") {
        T.expect(LocalLLM.hasCJK("これは日本語の文書です"), "Japanese → CJK")
        T.expect(LocalLLM.hasCJK("금융위원회 보고서"), "Korean → CJK")
        T.expect(!LocalLLM.hasCJK("The quarterly report shows growth"), "English → not CJK")
        T.expect(LocalLLM.inputBudget(forCJK: true) < LocalLLM.inputBudget(forCJK: false),
                 "CJK budget is tighter than Latin")
    }

    T.group("AskService builds context and explains gaps") {
        // A readable file → its body is the context, no reason.
        let md = dir.appendingPathComponent("ask.md")
        try? "The deadline is March 3rd.".write(to: md, atomically: true, encoding: .utf8)
        let fileCtx = AskService.context(for: md, isFolder: false)
        T.expect(fileCtx.text.contains("March 3rd"), "file context is the body")
        T.expect(fileCtx.reason == nil, "readable file has no reason")

        // A folder with a doc → excerpt; an empty folder → a reason.
        let sub = dir.appendingPathComponent("askfolder-\(UUID().uuidString)")
        try? fm.createDirectory(at: sub, withIntermediateDirectories: true)
        let folderEmpty = AskService.context(for: sub, isFolder: true)
        T.expect(folderEmpty.text.isEmpty && folderEmpty.reason != nil,
                 "empty folder → reason, no context")
        try? "Quarterly numbers up 12%.".write(to: sub.appendingPathComponent("q.txt"),
                                               atomically: true, encoding: .utf8)
        let folderCtx = AskService.context(for: sub, isFolder: true)
        T.expect(folderCtx.text.contains("Quarterly"), "folder context gathers doc text")
    }

    T.group("hasSummarizableText classification") {
        func item(_ name: String) -> FileItem? {
            let u = dir.appendingPathComponent(name)
            fm.createFile(atPath: u.path, contents: Data("x".utf8))
            return FileItem(url: u)
        }
        T.expect(item("a.md")?.hasSummarizableText == true, "markdown summarizable")
        T.expect(item("b.txt")?.hasSummarizableText == true, "text summarizable")
        T.expect(item("c.json")?.hasSummarizableText == true, "json summarizable")
        T.expect(item("d.png")?.hasSummarizableText == false, "image not summarizable")
        T.expect(item("e.so")?.hasSummarizableText == false, "binary not summarizable")
    }
}
