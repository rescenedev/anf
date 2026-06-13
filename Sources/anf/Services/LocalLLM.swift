import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device language model via Apple's FoundationModels (the same model that
/// powers Apple Intelligence) — no bundle, no network, so the "telemetry 0"
/// promise holds even for summarize / Q&A / smart-rename. Requires macOS 26 +
/// Apple Intelligence enabled on an eligible Mac; everything below degrades
/// gracefully (returns nil / a status) on older systems so the 14+ build keeps
/// compiling and running.
enum LocalLLM {

    enum Status: Equatable {
        case available
        case needsNewerOS          // < macOS 26 — no FoundationModels at all
        case appleIntelligenceOff  // 26 but AI not turned on
        case modelNotReady         // 26, downloading / warming up
        case unsupportedDevice     // ineligible hardware
    }

    /// Why-it-can't, for a one-line UI hint.
    static var status: Status {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable(let reason):
                switch reason {
                case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
                case .modelNotReady: return .modelNotReady
                default: return .unsupportedDevice
                }
            }
        }
        #endif
        return .needsNewerOS
    }

    static var isAvailable: Bool { status == .available }

    /// Localized one-liner explaining an unavailable state.
    static func unavailableHint(_ s: Status) -> String {
        switch s {
        case .available: return ""
        case .needsNewerOS: return L("Requires macOS 26 (Apple Intelligence)", "macOS 26(Apple Intelligence)가 필요합니다")
        case .appleIntelligenceOff: return L("Turn on Apple Intelligence in System Settings", "시스템 설정에서 Apple Intelligence를 켜세요")
        case .modelNotReady: return L("The model is still downloading — try again shortly", "모델을 내려받는 중입니다 — 잠시 후 다시 시도하세요")
        case .unsupportedDevice: return L("This Mac doesn't support Apple Intelligence", "이 Mac은 Apple Intelligence를 지원하지 않습니다")
        }
    }

    /// Generate text from instructions + prompt, fully on-device. Returns nil if
    /// unavailable or the model errors. `maxTokens` bounds the response.
    static func generate(instructions: String, prompt: String, maxTokens: Int = 600) async -> String? {
        #if canImport(FoundationModels)
        if #available(macOS 26, *), isAvailable {
            do {
                let session = LanguageModelSession(instructions: instructions)
                let opts = GenerationOptions(temperature: 0.3, maximumResponseTokens: maxTokens)
                let response = try await session.respond(to: prompt, options: opts)
                return response.content.trimmingCharacters(in: .whitespacesAndNewlines)
            } catch {
                return nil
            }
        }
        #endif
        return nil
    }

    /// The on-device context window is small, so cap input. ~12k chars is a safe
    /// budget for a summary; the head of a document carries the gist anyway.
    static let inputCharBudget = 12_000

    /// Summarize a document's body. Answers in the document's own language
    /// (Korean docs → Korean summary). nil when LLM is unavailable / empty input.
    static func summarize(_ text: String) async -> String? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        let clipped = body.count > inputCharBudget ? String(body.prefix(inputCharBudget)) : body
        let instructions = """
        You summarize documents. Reply in the SAME language as the document.
        Be concise: 2–4 sentences capturing the purpose and key points. No preamble.
        """
        return await generate(instructions: instructions, prompt: clipped, maxTokens: 400)
    }
}
