import Foundation

/// Optional Claude (Anthropic API) backend for the AI features. Unlike the Apple
/// on-device model and a localhost LLM, THIS SENDS CONTENT TO ANTHROPIC'S CLOUD —
/// so it's strictly opt-in, configured in the ⌘, settings file, and the UI calls
/// it out as cloud (not on-device). Native Messages API, no SDK.
///
///     "aiProvider": "claude",
///     "aiApiKey": "sk-ant-…",
///     "aiModel": "claude-opus-4-8"   // optional; this is the default
enum ClaudeLLM {
    private static let apiKeyKey = "anf.aiApiKey"
    private static let modelKey = "anf.aiModel"

    static let defaultModel = "claude-opus-4-8"

    static var apiKey: String? {
        let s = (UserDefaults.standard.string(forKey: apiKeyKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { return s }
        // Fall back to the standard env var so Claude "just works" when anf is
        // launched from a shell that has it (no key in the settings file).
        let env = (ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"] ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return env.isEmpty ? nil : env
    }
    static var model: String {
        let s = (UserDefaults.standard.string(forKey: modelKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? defaultModel : normalize(s)
    }

    /// Forgive common shorthands so a settings typo ("opus-4.8", "opus") still
    /// resolves to a valid Anthropic model id instead of a 404.
    static func normalize(_ m: String) -> String {
        let k = m.lowercased().replacingOccurrences(of: " ", with: "")
        if k.hasPrefix("claude-") { return m }          // already a full id
        let aliases: [String: String] = [
            "opus": "claude-opus-4-8", "opus-4.8": "claude-opus-4-8", "opus4.8": "claude-opus-4-8",
            "opus-4-8": "claude-opus-4-8",
            "sonnet": "claude-sonnet-4-6", "sonnet-4.6": "claude-sonnet-4-6", "sonnet4.6": "claude-sonnet-4-6",
            "haiku": "claude-haiku-4-5", "haiku-4.5": "claude-haiku-4-5", "haiku4.5": "claude-haiku-4-5",
        ]
        return aliases[k] ?? m
    }

    /// Configured = an API key is set.
    static var isConfigured: Bool { apiKey != nil }

    static func generate(instructions: String, prompt: String, maxTokens: Int, temperature: Double = 0.3) async -> String? {
        guard let key = apiKey, let url = URL(string: "https://api.anthropic.com/v1/messages") else { return nil }
        let body: [String: Any] = [
            "model": model,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "system": instructions,
            "messages": [["role": "user", "content": prompt]],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return nil }

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(key, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.httpBody = data
        req.timeoutInterval = 120

        guard let (respData, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode),
              let json = (try? JSONSerialization.jsonObject(with: respData)) as? [String: Any],
              let content = json["content"] as? [[String: Any]]
        else { return nil }
        // Concatenate all text blocks.
        let text = content.compactMap { ($0["type"] as? String) == "text" ? $0["text"] as? String : nil }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    static func reachable() async -> Bool {
        await generate(instructions: "You are a health check.", prompt: "Reply with: ok", maxTokens: 8) != nil
    }
}
