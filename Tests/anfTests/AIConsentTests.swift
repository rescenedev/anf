import Foundation
@testable import anf

/// Privacy regression guard for AI-002: a stray shell ANTHROPIC_API_KEY must NOT
/// make a non-claude provider send to the cloud. Pure logic over UserDefaults +
/// env + the Keychain test seam.
func runAIConsentTests() {
    let d = UserDefaults.standard
    let savedProvider = d.string(forKey: "anf.aiProvider")
    let savedOverride = AISecret.testOverride
    setenv("ANTHROPIC_API_KEY", "sk-ant-env-regression", 1)
    defer {
        unsetenv("ANTHROPIC_API_KEY")
        if let savedProvider { d.set(savedProvider, forKey: "anf.aiProvider") }
        else { d.removeObject(forKey: "anf.aiProvider") }
        AISecret.testOverride = savedOverride
    }

    T.group("AI-002: env key never routes a non-claude provider to the cloud") {
        AISecret.testOverride = .some(nil)            // no in-app (Keychain) key
        d.set("local", forKey: "anf.aiProvider")
        T.equal(ClaudeLLM.apiKey, nil, "provider=local + env key → apiKey nil (no silent cloud)")
        d.set("apple", forKey: "anf.aiProvider")
        T.equal(ClaudeLLM.apiKey, nil, "provider=apple + env key → apiKey nil")
        d.set("auto", forKey: "anf.aiProvider")
        T.equal(ClaudeLLM.apiKey, nil, "provider=auto + env key → apiKey nil (auto must not auto-route)")
    }

    T.group("AI-002: explicit consent paths still work") {
        AISecret.testOverride = .some(nil)
        d.set("claude", forKey: "anf.aiProvider")
        T.equal(ClaudeLLM.apiKey, "sk-ant-env-regression", "explicit 'claude' provider honors the env key")
        // An in-app (Keychain) key is explicit consent and always wins.
        AISecret.testOverride = .some("sk-keychain-explicit")
        d.set("local", forKey: "anf.aiProvider")
        T.equal(ClaudeLLM.apiKey, "sk-keychain-explicit", "in-app Keychain key honored regardless of provider")
    }
}
