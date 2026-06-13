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
            var result: String? = "unset"
            Task { result = await SummaryService.summarize(url: md); sem.signal() }
            _ = sem.wait(timeout: .now() + 5)
            T.expect(result == nil, "no model → summarize returns nil, not a crash/hang")
        }
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
