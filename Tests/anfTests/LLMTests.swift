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

    // Isolate the WHOLE suite run from the real Keychain — the very first
    // `LocalLLM.status` read below routes through AISecret → Keychain, which on a
    // headless/ad-hoc build would block on a keychain trust prompt. Set the seam
    // up front (the provider-routing group below re-saves/restores it locally).
    let outerOverride = AISecret.testOverride
    AISecret.testOverride = .some(nil)
    defer { AISecret.testOverride = outerOverride }

    T.group("LocalLLM availability gating") {
        // Whatever the machine reports, status maps to a stable hint and
        // isAvailable tracks the "usable" states.
        let s = LocalLLM.status
        let usable: Set<LocalLLM.Status> = [.available, .customEndpoint, .claudeCloud]
        T.equal(LocalLLM.isAvailable, usable.contains(s), "isAvailable tracks usable states")
        if !usable.contains(s) {
            T.expect(!LocalLLM.unavailableHint(s).isEmpty, "unavailable states carry a hint")
        }
        T.equal(LocalLLM.unavailableHint(.available), "", "available has no hint")
    }

    T.group("LLM provider routing") {
        let d = UserDefaults.standard
        let keys = ["anf.aiProvider", "anf.aiEndpoint", "anf.aiModel"]
        let saved = keys.map { d.string(forKey: $0) }
        let savedOverride = AISecret.testOverride
        defer {
            for (k, v) in zip(keys, saved) { d.set(v, forKey: k) }
            AISecret.testOverride = savedOverride
        }

        keys.forEach { d.removeObject(forKey: $0) }
        AISecret.testOverride = .some(nil)        // isolate from the real Keychain key
        T.equal(LocalLLM.provider, .apple, "no config → Apple on-device")

        d.set("http://localhost:11434/v1", forKey: "anf.aiEndpoint")
        d.set("local", forKey: "anf.aiProvider")
        T.equal(LocalLLM.provider, .local, "endpoint + local → local")
        T.expect(RemoteLLM.isConfigured, "endpoint set → RemoteLLM configured")

        d.set("claude", forKey: "anf.aiProvider")
        AISecret.testOverride = .some("sk-ant-test")   // key present (mocked Keychain)
        T.equal(LocalLLM.provider, .claude, "key + claude → claude")
        T.equal(LocalLLM.status, .claudeCloud, "claude provider → cloud status")
        T.expect(LocalLLM.isAvailable, "configured cloud provider is available")
    }

    T.group("AISecret scrubs plaintext keys from settings JSON") {
        let json = "{\n  \"aiProvider\": \"claude\",\n  \"aiApiKey\": \"sk-ant-secret123\",\n  \"aiModel\": \"\"\n}"
        T.equal(AISecret.jsonStringValue(of: "aiApiKey", in: json), "sk-ant-secret123", "reads the key value")
        let scrubbed = AISecret.scrub(key: "aiApiKey", in: json)
        T.equal(AISecret.jsonStringValue(of: "aiApiKey", in: scrubbed), "", "scrub empties the value")
        T.expect(!scrubbed.contains("sk-ant-secret123"), "secret gone after scrub")
        T.expect(scrubbed.contains("\"aiProvider\": \"claude\""), "other keys untouched")
    }

    T.group("RemoteLLM.chatURL normalizes endpoints") {
        T.equal(RemoteLLM.chatURL("http://localhost:11434/v1")?.absoluteString,
                "http://localhost:11434/v1/chat/completions", "appends path to /v1 base")
        T.equal(RemoteLLM.chatURL("localhost:1234")?.absoluteString,
                "http://localhost:1234/v1/chat/completions", "bare host → http + /v1/chat/completions")
        T.equal(RemoteLLM.chatURL("http://x/v1/chat/completions")?.absoluteString,
                "http://x/v1/chat/completions", "full path left as-is")
        T.equal(ClaudeLLM.defaultModel, "claude-opus-4-8", "Claude default is Opus 4.8")
        T.equal(ClaudeLLM.normalize("opus-4.8"), "claude-opus-4-8", "shorthand alias resolves")
        T.equal(ClaudeLLM.normalize("opus"), "claude-opus-4-8", "bare 'opus' resolves")
        T.equal(ClaudeLLM.normalize("claude-sonnet-4-6"), "claude-sonnet-4-6", "full id left as-is")
        T.equal(ClaudeLLM.normalize("my-custom-model"), "my-custom-model", "unknown left as-is")
    }

    T.group("RemoteLLM.stripThink removes inline reasoning") {
        T.equal(RemoteLLM.stripThink("<think>hmm let me see</think>The answer is 42."),
                "The answer is 42.", "strips a <think> block")
        T.equal(RemoteLLM.stripThink("plain answer"), "plain answer", "leaves plain text")
        T.equal(RemoteLLM.stripThink("<think>unterminated reasoning"), "",
                "drops an unterminated <think> tail")
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
        // Budget only varies by CJK on the on-device/local backends — Claude's 1M
        // window is flat — so pin the provider to Apple (no key, forced provider)
        // for this check. Otherwise a real Keychain key routes to .claude.
        let d = UserDefaults.standard
        let savedOverride = AISecret.testOverride
        let savedProvider = d.string(forKey: "anf.aiProvider")
        let savedEndpoint = d.string(forKey: "anf.aiEndpoint")
        defer {
            AISecret.testOverride = savedOverride
            d.set(savedProvider, forKey: "anf.aiProvider")
            d.set(savedEndpoint, forKey: "anf.aiEndpoint")
        }
        AISecret.testOverride = .some(nil)
        d.removeObject(forKey: "anf.aiEndpoint")
        d.set("apple", forKey: "anf.aiProvider")
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
